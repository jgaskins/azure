require "db/pool"

require "./version"

# TODO: Write documentation for `Azure`
module Azure
  class Client
    # TODO: Set the base_uri to the correct default value
    def initialize(@base_uri = URI.parse("https://azure.microsoft.com"))
      @http = DB::Pool(HTTP::Client).new do
        http = HTTP::Client.new(base_uri)
        http.before_request do |request|
          request.headers["Authorization"] ||= "Bearer #{token}"
          request.headers["User-Agent"] ||= "https://github.com/jgaskins/azure"
        end
        http
      end
    end

    {% for method in %w[get post patch put delete] %}
      def {{method.id}}(
        path : String,
        headers : HTTP::Headers? = nil,
        body : IO | String | Nil = nil,
        *,
        as type : T.class,
      ) forall T
        checkout &.{{method.id}}(
          path: path,
          headers: headers,
          body: body,
        ) do |response|
          case response.status
          when .success?
            T.from_json(response.body_io)
          {% if T.nilable? %}
            when .not_found?
              nil
          {% end %}
          else
            raise Error.new(error_message(response))
          end
        end
      end
    {% end %}
  end

  private def error_message(response : HTTP::Client::Response)
    # TODO: Get the real error message
    if body = response.body_io?
      body.gets_to_end
    else
      response.body
    end
  end

  class Error < ::Exception
  end
end
