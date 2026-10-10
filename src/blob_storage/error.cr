require "xml"
require "http/client/response"

module Azure::BlobStorage
  class Error < ::Exception
  end

  # Raised when the Blob service returns an error response. `code` is the
  # [Azure error code](https://learn.microsoft.com/en-us/rest/api/storageservices/blob-service-error-codes),
  # such as `BlobAlreadyExists` or `AuthenticationFailed`.
  class RequestError < Error
    getter status : HTTP::Status
    getter code : String?
    getter request_id : String?

    def self.new(response : HTTP::Client::Response)
      code = response.headers["x-ms-error-code"]?
      message = nil
      body = response.body_io?.try(&.gets_to_end) || response.body
      unless body.empty?
        begin
          if error = XML.parse(body).first_element_child
            error.children.each do |child|
              case child.name
              when "Code"    then code ||= child.content
              when "Message" then message = child.content.lines.first?
              end
            end
          end
        rescue XML::Error
          message = body
        end
      end
      message ||= response.status.description || "Request failed"

      new(
        "#{response.status.code} #{code}: #{message}",
        status: response.status,
        code: code,
        request_id: response.headers["x-ms-request-id"]?,
      )
    end

    def initialize(message : String, *, @status, @code, @request_id)
      super message
    end
  end
end
