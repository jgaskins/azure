require "http/request"
require "openssl/hmac"
require "base64"

module Azure::BlobStorage
  # Adds authorization to requests made to the Blob service.
  module Credential
    abstract def authorize(request : HTTP::Request) : Nil
  end

  # Signs requests with the storage account's access key, as described in
  # [Authorize with Shared Key](https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key).
  struct SharedKeyCredential
    include Credential

    getter account_name : String
    @key : Bytes

    def initialize(@account_name, account_key : String)
      @key = Base64.decode(account_key)
    end

    def authorize(request : HTTP::Request) : Nil
      signature = Base64.strict_encode(OpenSSL::HMAC.digest(:sha256, @key, string_to_sign(request)))
      request.headers["Authorization"] = "SharedKey #{account_name}:#{signature}"
    end

    # :nodoc:
    def string_to_sign(request : HTTP::Request) : String
      headers = request.headers
      content_length = headers["Content-Length"]?
      content_length = nil if content_length == "0"
      date = headers["Date"]? unless headers.has_key?("x-ms-date")

      String.build do |str|
        str << request.method << '\n'
        str << headers["Content-Encoding"]? << '\n'
        str << headers["Content-Language"]? << '\n'
        str << content_length << '\n'
        str << headers["Content-MD5"]? << '\n'
        str << headers["Content-Type"]? << '\n'
        str << date << '\n'
        str << headers["If-Modified-Since"]? << '\n'
        str << headers["If-Match"]? << '\n'
        str << headers["If-None-Match"]? << '\n'
        str << headers["If-Unmodified-Since"]? << '\n'
        str << headers["Range"]? << '\n'

        canonicalized_headers = headers
          .compact_map { |name, values| {name.downcase, values} if name.downcase.starts_with?("x-ms-") }
          .sort_by!(&.[0])
        canonicalized_headers.each do |(name, values)|
          str << name << ':' << values.join(',').strip << '\n'
        end

        str << '/' << account_name << request.path
        request.query_params
          .map { |name, _| name }
          .uniq!
          .sort_by!(&.downcase)
          .each do |name|
            str << '\n' << name.downcase << ':'
            request.query_params.fetch_all(name).sort!.join str, ','
          end
      end
    end
  end

  # Authorizes requests with a [shared access signature](https://learn.microsoft.com/en-us/rest/api/storageservices/delegate-access-with-shared-access-signature)
  # token, such as `sv=2024-11-04&ss=b&srt=sco&sp=rwdlac&se=...&sig=...`.
  struct SASCredential
    include Credential

    @params : URI::Params

    def initialize(token : String)
      @params = URI::Params.parse(token.lchop('?'))
    end

    def authorize(request : HTTP::Request) : Nil
      params = request.query_params.dup
      @params.each { |name, value| params.add name, value }
      request.query = params.to_s
    end
  end
end
