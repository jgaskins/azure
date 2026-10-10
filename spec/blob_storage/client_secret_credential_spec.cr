require "spec"
require "http/server"
require "../../src/blob_storage"

# A stand-in for the Entra ID token endpoint
private class FakeTokenServer
  getter requests = [] of {String, URI::Params}
  property status = HTTP::Status::OK
  property expires_in = 3599
  getter uri : URI

  def initialize
    @server = HTTP::Server.new do |context|
      form = URI::Params.parse(context.request.body.try(&.gets_to_end) || "")
      requests << {context.request.path, form}
      context.response.status = status
      context.response.content_type = "application/json"
      if status.success?
        {token_type: "Bearer", expires_in: expires_in, access_token: "token-#{requests.size}"}.to_json context.response
      else
        {error: "invalid_client", error_description: "AADSTS7000215: Invalid client secret provided.\r\nTrace ID: abc"}.to_json context.response
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @uri = URI.parse("http://127.0.0.1:#{address.port}")
    spawn @server.listen
  end

  def close
    @server.close
  end
end

module Azure::BlobStorage
  describe ClientSecretCredential do
    it "requests a token with the client credentials grant and uses it as a bearer token" do
      server = FakeTokenServer.new
      credential = ClientSecretCredential.new("my-tenant", "my-client", "my-secret", authority: server.uri)
      request = HTTP::Request.new("GET", "/container/blob")

      credential.authorize request

      request.headers["Authorization"].should eq "Bearer token-1"
      path, form = server.requests.first
      path.should eq "/my-tenant/oauth2/v2.0/token"
      form["grant_type"].should eq "client_credentials"
      form["client_id"].should eq "my-client"
      form["client_secret"].should eq "my-secret"
      form["scope"].should eq "https://storage.azure.com/.default"
    ensure
      server.try &.close
    end

    it "caches the token until it's about to expire" do
      server = FakeTokenServer.new
      credential = ClientSecretCredential.new("t", "c", "s", authority: server.uri)

      credential.token.should eq "token-1"
      credential.token.should eq "token-1"
      server.requests.size.should eq 1

      # Tokens that expire within the refresh margin are refetched every time
      server2 = FakeTokenServer.new
      server2.expires_in = 60
      short_lived = ClientSecretCredential.new("t", "c", "s", authority: server2.uri)
      short_lived.token.should eq "token-1"
      short_lived.token.should eq "token-2"
    ensure
      server.try &.close
      server2.try &.close
    end

    it "raises with Entra's error message when authentication fails" do
      server = FakeTokenServer.new
      server.status = HTTP::Status::UNAUTHORIZED
      credential = ClientSecretCredential.new("t", "c", "wrong", authority: server.uri)

      expect_raises AuthenticationError, "401 invalid_client: AADSTS7000215: Invalid client secret provided." do
        credential.token
      end
    ensure
      server.try &.close
    end

    it "reads its configuration from the environment" do
      credential = ClientSecretCredential.from_env({
        "AZURE_TENANT_ID"     => "tenant",
        "AZURE_CLIENT_ID"     => "client",
        "AZURE_CLIENT_SECRET" => "secret",
      })

      credential.tenant_id.should eq "tenant"
      credential.client_id.should eq "client"
      credential.authority.should eq URI.parse("https://login.microsoftonline.com")
    end
  end
end
