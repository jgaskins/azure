require "http/client"
require "db/pool"
require "random/secure"

require "../version"
require "./credential"
require "./client_secret_credential"
require "./connection_string"
require "./properties"
require "./error"

module Azure::BlobStorage
  class Client
    DEFAULT_API_VERSION            = "2024-11-04"
    DEFAULT_MAX_SINGLE_UPLOAD_SIZE = 256 * 1024 * 1024
    DEFAULT_BLOCK_SIZE             = 8 * 1024 * 1024

    getter endpoint : URI
    getter api_version : String
    # Uploads larger than this, or from an `IO` whose size we can't determine,
    # are sent as a series of blocks rather than in a single request.
    getter max_single_upload_size : Int64
    # The size of each block for uploads sent in multiple blocks. Azure allows
    # up to 50,000 blocks per blob, so the default of 8MiB supports blobs up to
    # about 390GiB.
    getter block_size : Int32

    @credential : Credential?
    @http : DB::Pool(HTTP::Client)

    # Create a client from an Azure Storage connection string, such as the one
    # shown under "Access keys" for your storage account in the Azure portal.
    #
    # ```
    # Azure::BlobStorage::Client.from_connection_string(ENV["AZURE_STORAGE_CONNECTION_STRING"])
    # Azure::BlobStorage::Client.from_connection_string("UseDevelopmentStorage=true") # Azurite
    # ```
    def self.from_connection_string(
      connection_string : String,
      *,
      api_version : String = DEFAULT_API_VERSION,
      max_single_upload_size : Int = DEFAULT_MAX_SINGLE_UPLOAD_SIZE,
      block_size : Int32 = DEFAULT_BLOCK_SIZE,
    ) : self
      parsed = ConnectionString.parse(connection_string)
      new(
        endpoint: parsed.blob_endpoint,
        credential: parsed.credential,
        api_version: api_version,
        max_single_upload_size: max_single_upload_size,
        block_size: block_size,
      )
    end

    # Create a client authenticated with the storage account's access key.
    def self.new(
      account_name : String,
      account_key : String,
      endpoint : URI = URI.parse("https://#{account_name}.blob.core.windows.net"),
      *,
      api_version : String = DEFAULT_API_VERSION,
      max_single_upload_size : Int = DEFAULT_MAX_SINGLE_UPLOAD_SIZE,
      block_size : Int32 = DEFAULT_BLOCK_SIZE,
    ) : self
      new(
        endpoint: endpoint,
        credential: SharedKeyCredential.new(account_name, account_key),
        api_version: api_version,
        max_single_upload_size: max_single_upload_size,
        block_size: block_size,
      )
    end

    # Create a client for the storage account named `account_name` that
    # authorizes requests with `credential`, such as a `ClientSecretCredential`
    # for a service principal.
    #
    # ```
    # Azure::BlobStorage::Client.new(
    #   account_name: "mystorageaccount",
    #   credential: Azure::BlobStorage::ClientSecretCredential.from_env,
    # )
    # ```
    def self.new(
      account_name : String,
      credential : Credential,
      *,
      api_version : String = DEFAULT_API_VERSION,
      max_single_upload_size : Int = DEFAULT_MAX_SINGLE_UPLOAD_SIZE,
      block_size : Int32 = DEFAULT_BLOCK_SIZE,
    ) : self
      new(
        endpoint: URI.parse("https://#{account_name}.blob.core.windows.net"),
        credential: credential,
        api_version: api_version,
        max_single_upload_size: max_single_upload_size,
        block_size: block_size,
      )
    end

    # Create a client with an arbitrary `Credential`, or `nil` for anonymous
    # access to public containers.
    def initialize(
      @endpoint : URI,
      @credential : Credential?,
      *,
      @api_version : String = DEFAULT_API_VERSION,
      max_single_upload_size : Int = DEFAULT_MAX_SINGLE_UPLOAD_SIZE,
      @block_size : Int32 = DEFAULT_BLOCK_SIZE,
      @connect_timeout : Time::Span = 5.seconds,
    )
      @max_single_upload_size = max_single_upload_size.to_i64
      @http = DB::Pool(HTTP::Client).new(DB::Pool::Options.new(max_idle_pool_size: 25)) do
        http = HTTP::Client.new(endpoint)
        http.connect_timeout = connect_timeout
        # Blobs stored with a Content-Encoding should be returned exactly as
        # they were stored rather than transparently decompressed.
        http.compress = false
        http
      end
    end

    # Upload `body` to the blob named `blob` in `container`, replacing any
    # existing blob with that name unless `overwrite` is `false`, in which case
    # a `RequestError` with code `BlobAlreadyExists` is raised.
    #
    # The `content_*` and `cache_control` arguments set the corresponding
    # headers served when the blob is downloaded. `metadata` sets arbitrary
    # name/value pairs on the blob, whose names must be valid C# identifiers.
    #
    # ```
    # File.open "photo.jpg" do |file|
    #   blobs.upload "photos", "2026/10/photo.jpg", file,
    #     content_type: "image/jpeg",
    #     metadata: {"uploaded_by" => "jamie"}
    # end
    # ```
    def upload(
      container : String,
      blob : String,
      body : String | Bytes | IO,
      *,
      content_type : String? = nil,
      content_encoding : String? = nil,
      content_language : String? = nil,
      content_disposition : String? = nil,
      cache_control : String? = nil,
      metadata : Hash(String, String)? = nil,
      overwrite : Bool = true,
    ) : UploadResult
      headers = HTTP::Headers.new
      headers["x-ms-blob-content-type"] = content_type if content_type
      headers["x-ms-blob-content-encoding"] = content_encoding if content_encoding
      headers["x-ms-blob-content-language"] = content_language if content_language
      headers["x-ms-blob-content-disposition"] = content_disposition if content_disposition
      headers["x-ms-blob-cache-control"] = cache_control if cache_control
      metadata.try &.each do |name, value|
        headers["#{METADATA_PREFIX}#{name}"] = value
      end
      headers["If-None-Match"] = "*" unless overwrite

      path = blob_path(container, blob)
      case body
      in String, Bytes
        if body.bytesize <= max_single_upload_size
          put_blob path, headers, body, body.bytesize
        else
          upload_in_blocks path, headers, IO::Memory.new(body.to_slice, writable: false)
        end
      in IO
        remaining = (body.size - body.pos).to_i64 if body.responds_to?(:size) && body.responds_to?(:pos)
        if remaining && remaining <= max_single_upload_size
          put_blob path, headers, body, remaining
        else
          upload_in_blocks path, headers, body
        end
      end
    end

    # Get the properties and metadata of the blob named `blob` in `container`,
    # or `nil` if it does not exist.
    def properties(container : String, blob : String) : Properties?
      request "HEAD", blob_path(container, blob) do |response|
        case response.status
        when .success?   then Properties.new(response.headers)
        when .not_found? then nil
        else                  raise RequestError.new(response)
        end
      end
    end

    # Get just the user-defined metadata of the blob named `blob` in
    # `container`, or `nil` if it does not exist.
    def metadata(container : String, blob : String) : Hash(String, String)?
      properties(container, blob).try(&.metadata)
    end

    # Download the contents of the blob named `blob` in `container` into a
    # `String`, or return `nil` if it does not exist. Pass a `range` to get only
    # part of the blob.
    #
    # Since this loads the entire blob into memory, prefer the block form for
    # large blobs.
    def get(container : String, blob : String, *, range : Range? = nil) : String?
      get(container, blob, range: range, &.gets_to_end)
    end

    # Stream the contents of the blob named `blob` in `container`, yielding the
    # body as an `IO` along with the blob's `Properties`, and returning the
    # value of the block. If the blob does not exist, the block is not called
    # and this method returns `nil`.
    #
    # ```
    # blobs.get "photos", "2026/10/photo.jpg" do |io, properties|
    #   File.open("photo.jpg", "w") { |file| IO.copy io, file }
    # end
    # ```
    def get(container : String, blob : String, *, range : Range? = nil, & : IO, Properties -> T) : T? forall T
      headers = HTTP::Headers.new
      headers["x-ms-range"] = range_header(range) if range

      request "GET", blob_path(container, blob), headers do |response|
        case response.status
        when .success?
          yield response.body_io, Properties.new(response.headers)
        when .not_found?
          nil
        else
          raise RequestError.new(response)
        end
      end
    end

    # Delete the blob named `blob` in `container`, along with any snapshots.
    # Returns `false` if the blob did not exist.
    def delete(container : String, blob : String) : Bool
      headers = HTTP::Headers{"x-ms-delete-snapshots" => "include"}
      request "DELETE", blob_path(container, blob), headers do |response|
        case response.status
        when .success?   then true
        when .not_found? then false
        else                  raise RequestError.new(response)
        end
      end
    end

    # Create a container, returning `false` if it already exists.
    def create_container(name : String) : Bool
      request "PUT", container_path(name), query: URI::Params{"restype" => "container"}, body: "" do |response|
        case response.status
        when .success?  then true
        when .conflict? then false
        else                 raise RequestError.new(response)
        end
      end
    end

    # Delete a container and all of the blobs in it, returning `false` if it
    # did not exist.
    def delete_container(name : String) : Bool
      request "DELETE", container_path(name), query: URI::Params{"restype" => "container"} do |response|
        case response.status
        when .success?   then true
        when .not_found? then false
        else                  raise RequestError.new(response)
        end
      end
    end

    private def put_blob(path : String, headers : HTTP::Headers, body, content_length : Int) : UploadResult
      headers = headers.dup
      headers["x-ms-blob-type"] = "BlockBlob"
      headers["Content-Length"] = content_length.to_s

      request "PUT", path, headers, body do |response|
        raise RequestError.new(response) unless response.status.success?
        UploadResult.new(response.headers)
      end
    end

    # Uploads the blob using [Put Block](https://learn.microsoft.com/en-us/rest/api/storageservices/put-block)
    # and [Put Block List](https://learn.microsoft.com/en-us/rest/api/storageservices/put-block-list),
    # reading only `block_size` bytes into memory at a time.
    private def upload_in_blocks(path : String, headers : HTTP::Headers, io : IO) : UploadResult
      buffer = Bytes.new(block_size)
      chunk = read_chunk(io, buffer)

      # If the whole IO fit into a single block, there's no need for the extra
      # round trips.
      if chunk.size < buffer.size
        return put_blob(path, headers, chunk, chunk.size)
      end

      # Block IDs must all be the same length within a blob. The random prefix
      # keeps concurrent uploads to the same blob from clobbering each other's
      # uncommitted blocks.
      prefix = Random::Secure.hex(8)
      block_ids = [] of String
      until chunk.empty?
        block_id = Base64.strict_encode("#{prefix}-#{block_ids.size.to_s.rjust(6, '0')}")
        query = URI::Params{"comp" => "block", "blockid" => block_id}
        block_headers = HTTP::Headers{"Content-Length" => chunk.size.to_s}
        request "PUT", path, block_headers, chunk, query: query do |response|
          raise RequestError.new(response) unless response.status.success?
        end
        block_ids << block_id
        chunk = read_chunk(io, buffer)
      end

      body = String.build do |str|
        str << %{<?xml version="1.0" encoding="utf-8"?><BlockList>}
        block_ids.each { |id| str << "<Latest>" << id << "</Latest>" }
        str << "</BlockList>"
      end
      headers = headers.dup
      headers["Content-Length"] = body.bytesize.to_s

      request "PUT", path, headers, body, query: URI::Params{"comp" => "blocklist"} do |response|
        raise RequestError.new(response) unless response.status.success?
        UploadResult.new(response.headers)
      end
    end

    # Fill `buffer` from `io`, returning a slice of fewer bytes only if `io`
    # runs out first.
    private def read_chunk(io : IO, buffer : Bytes) : Bytes
      filled = 0
      while filled < buffer.size && (count = io.read(buffer + filled)) > 0
        filled += count
      end
      buffer[0, filled]
    end

    private def range_header(range : Range) : String
      start = range.begin || 0
      if finish = range.end
        finish -= 1 if range.excludes_end?
        "bytes=#{start}-#{finish}"
      else
        "bytes=#{start}-"
      end
    end

    private def container_path(container : String) : String
      "#{endpoint.path.rchop('/')}/#{URI.encode_path_segment(container)}"
    end

    private def blob_path(container : String, blob : String) : String
      "#{container_path(container)}/#{URI.encode_path(blob)}"
    end

    private def request(
      method : String,
      path : String,
      headers : HTTP::Headers = HTTP::Headers.new,
      body : String | Bytes | IO | Nil = nil,
      *,
      query : URI::Params? = nil,
      &
    )
      headers = headers.dup
      headers["x-ms-date"] = HTTP.format_time(Time.utc)
      headers["x-ms-version"] = api_version
      headers["User-Agent"] ||= "https://github.com/jgaskins/azure v#{Azure::VERSION}"

      resource = query && !query.empty? ? "#{path}?#{query}" : path
      request = HTTP::Request.new(method, resource, headers, body)
      @credential.try &.authorize(request)

      @http.checkout do |http|
        http.exec request do |response|
          result = yield response
          # Any part of the body the caller didn't read is still on the wire,
          # so we need to consume it before this connection can be reused.
          response.body_io.skip_to_end
          result
        end
      rescue ex : IO::Error
        # The connection may be left mid-response, so don't reuse it
        http.close
        raise ex
      end
    end
  end
end
