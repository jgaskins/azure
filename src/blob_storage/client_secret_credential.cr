require "http/client"
require "json"

require "./credential"
require "./error"

module Azure::BlobStorage
  # Authorizes requests as a Microsoft Entra ID service principal (app
  # registration) using its client secret, via the
  # [OAuth 2.0 client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow).
  #
  # The service principal needs a data-plane role on the storage account or
  # container, such as "Storage Blob Data Contributor" (read/write) or
  # "Storage Blob Data Reader" (read-only). Management roles like "Owner" or
  # "Contributor" don't grant access to blob contents.
  #
  # Tokens are cached and refreshed shortly before they expire, so a single
  # instance can be shared across a long-lived client.
  #
  # ```
  # credential = Azure::BlobStorage::ClientSecretCredential.new(
  #   tenant_id: ENV["AZURE_TENANT_ID"],
  #   client_id: ENV["AZURE_CLIENT_ID"],
  #   client_secret: ENV["AZURE_CLIENT_SECRET"],
  # )
  # ```
  class ClientSecretCredential
    include Credential

    DEFAULT_AUTHORITY = URI.parse("https://login.microsoftonline.com")
    DEFAULT_SCOPE     = "https://storage.azure.com/.default"
    # Refresh tokens this long before they actually expire, so a request
    # signed with a token doesn't reach Azure after it's expired.
    REFRESH_MARGIN = 5.minutes

    getter tenant_id : String
    getter client_id : String
    getter authority : URI
    getter scope : String
    @client_secret : String
    @token : String? = nil
    @expires_at : Time = Time::UNIX_EPOCH
    @mutex = Mutex.new

    # Create a credential from the `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and
    # `AZURE_CLIENT_SECRET` environment variables, the same ones used by the
    # official Azure SDKs and CLI tooling.
    def self.from_env(env = ENV) : self
      new(
        tenant_id: env["AZURE_TENANT_ID"],
        client_id: env["AZURE_CLIENT_ID"],
        client_secret: env["AZURE_CLIENT_SECRET"],
        authority: env["AZURE_AUTHORITY_HOST"]?.try { |host| URI.parse(host) } || DEFAULT_AUTHORITY,
      )
    end

    # `authority` only needs to be changed for sovereign clouds, such as
    # `https://login.microsoftonline.us` for Azure Government.
    def initialize(
      @tenant_id,
      @client_id,
      @client_secret : String,
      *,
      @authority = DEFAULT_AUTHORITY,
      @scope = DEFAULT_SCOPE,
    )
    end

    def authorize(request : HTTP::Request) : Nil
      request.headers["Authorization"] = "Bearer #{token}"
    end

    # The current access token, fetching a new one if it has expired or is
    # about to.
    def token : String
      @mutex.synchronize do
        token = @token
        if token.nil? || Time.utc >= @expires_at - REFRESH_MARGIN
          token = fetch_token
        end
        token
      end
    end

    private def fetch_token : String
      form = URI::Params.build do |params|
        params.add "grant_type", "client_credentials"
        params.add "client_id", client_id
        params.add "client_secret", @client_secret
        params.add "scope", scope
      end
      path = "#{authority.path.rchop('/')}/#{URI.encode_path_segment(tenant_id)}/oauth2/v2.0/token"

      requested_at = Time.utc
      response = HTTP::Client.new(authority) do |http|
        http.post path,
          headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
          body: form
      end

      unless response.success?
        error = TokenError.from_json(response.body) rescue nil
        raise AuthenticationError.new(
          "Could not get an access token for client #{client_id} in tenant #{tenant_id}: " \
          "#{response.status.code} #{error.try(&.error)}: #{error.try(&.error_description).try(&.lines.first?) || response.body}"
        )
      end

      result = TokenResponse.from_json(response.body)
      @expires_at = requested_at + result.expires_in.seconds
      @token = result.access_token
    end

    private struct TokenResponse
      include JSON::Serializable

      getter access_token : String
      getter expires_in : Int64
    end

    private struct TokenError
      include JSON::Serializable

      getter error : String?
      getter error_description : String?
    end
  end

  # Raised when a credential cannot obtain a token
  class AuthenticationError < Error
  end
end
