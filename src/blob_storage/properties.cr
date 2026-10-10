require "http/headers"
require "http/common"

module Azure::BlobStorage
  # :nodoc:
  METADATA_PREFIX = "x-ms-meta-"

  # System properties and user-defined metadata for a blob, as returned by
  # [Get Blob Properties](https://learn.microsoft.com/en-us/rest/api/storageservices/get-blob-properties).
  struct Properties
    getter content_length : Int64
    getter content_type : String?
    getter content_encoding : String?
    getter content_language : String?
    getter content_disposition : String?
    getter cache_control : String?
    # Base64-encoded MD5 hash of the blob's contents, if Azure has one
    getter content_md5 : String?
    getter etag : String
    getter last_modified : Time
    getter created_at : Time?
    getter blob_type : String?
    getter access_tier : String?
    getter version_id : String?
    getter metadata : Hash(String, String)
    # All response headers, for anything not exposed as a dedicated property
    getter headers : HTTP::Headers

    def initialize(@headers : HTTP::Headers)
      # For ranged downloads, Content-Length is the size of the range, so we
      # take the full size from Content-Range ("bytes 0-99/1234") instead.
      if (range = headers["Content-Range"]?) && (total = range.split('/', 2)[1]?.try(&.to_i64?))
        @content_length = total
      else
        @content_length = headers["Content-Length"]?.try(&.to_i64?) || 0i64
      end
      @content_type = headers["Content-Type"]?
      @content_encoding = headers["Content-Encoding"]?
      @content_language = headers["Content-Language"]?
      @content_disposition = headers["Content-Disposition"]?
      @cache_control = headers["Cache-Control"]?
      @content_md5 = headers["x-ms-blob-content-md5"]? || headers["Content-MD5"]?
      @etag = headers["ETag"]
      @last_modified = HTTP.parse_time(headers["Last-Modified"]) || raise Error.new("Could not parse Last-Modified header: #{headers["Last-Modified"].inspect}")
      @created_at = headers["x-ms-creation-time"]?.try { |time| HTTP.parse_time(time) }
      @blob_type = headers["x-ms-blob-type"]?
      @access_tier = headers["x-ms-access-tier"]?
      @version_id = headers["x-ms-version-id"]?

      @metadata = {} of String => String
      headers.each do |name, values|
        if name.downcase.starts_with?(METADATA_PREFIX)
          @metadata[name[METADATA_PREFIX.size..]] = values.join(',')
        end
      end
    end
  end

  # The result of uploading a blob
  struct UploadResult
    getter etag : String
    getter last_modified : Time
    getter version_id : String?

    def initialize(headers : HTTP::Headers)
      @etag = headers["ETag"]
      @last_modified = HTTP.parse_time(headers["Last-Modified"]) || raise Error.new("Could not parse Last-Modified header: #{headers["Last-Modified"].inspect}")
      @version_id = headers["x-ms-version-id"]?
    end
  end
end
