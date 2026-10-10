require "spec"
require "../../src/blob_storage"

module Azure::BlobStorage
  describe SharedKeyCredential do
    credential = SharedKeyCredential.new("myaccount", Base64.strict_encode("secret"))

    it "builds the string to sign from the request" do
      request = HTTP::Request.new("PUT", "/container/dir/my%20file.txt?comp=block&blockid=abc%3D", HTTP::Headers{
        "Content-Type"   => "text/plain",
        "X-MS-Version"   => "2024-11-04",
        "x-ms-date"      => "Fri, 09 Oct 2026 00:00:00 GMT",
        "x-ms-meta-Name" => "  value  ",
        "If-None-Match"  => "*",
        "Date"           => "ignored because x-ms-date is set",
        "User-Agent"     => "not signed",
      }, body: "hello world")

      credential.string_to_sign(request).should eq [
        "PUT",
        "",           # Content-Encoding
        "",           # Content-Language
        "11",         # Content-Length
        "",           # Content-MD5
        "text/plain", # Content-Type
        "",           # Date
        "",           # If-Modified-Since
        "",           # If-Match
        "*",          # If-None-Match
        "",           # If-Unmodified-Since
        "",           # Range
        "x-ms-date:Fri, 09 Oct 2026 00:00:00 GMT",
        "x-ms-meta-name:value",
        "x-ms-version:2024-11-04",
        "/myaccount/container/dir/my%20file.txt",
        "blockid:abc=",
        "comp:block",
      ].join('\n')
    end

    it "leaves Content-Length empty when it is zero" do
      request = HTTP::Request.new("PUT", "/container?restype=container", body: "")

      credential.string_to_sign(request).lines[3].should eq ""
    end

    it "adds the Authorization header" do
      request = HTTP::Request.new("GET", "/container/blob")
      credential.authorize request

      expected = Base64.strict_encode(OpenSSL::HMAC.digest(:sha256, "secret", credential.string_to_sign(request)))
      request.headers["Authorization"].should eq "SharedKey myaccount:#{expected}"
    end
  end

  describe SASCredential do
    it "appends the token to the query string" do
      request = HTTP::Request.new("GET", "/container/blob?comp=metadata")
      SASCredential.new("?sv=2024-11-04&sig=abc%2Fdef").authorize request

      request.query_params["comp"].should eq "metadata"
      request.query_params["sv"].should eq "2024-11-04"
      request.query_params["sig"].should eq "abc/def"
    end
  end
end
