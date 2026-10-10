require "spec"
require "../../src/blob_storage"

module Azure::BlobStorage
  describe ConnectionString do
    it "parses an account key connection string" do
      parsed = ConnectionString.parse("DefaultEndpointsProtocol=https;AccountName=myaccount;AccountKey=#{Base64.strict_encode("key")};EndpointSuffix=core.windows.net")

      parsed.blob_endpoint.should eq URI.parse("https://myaccount.blob.core.windows.net")
      parsed.credential.as(SharedKeyCredential).account_name.should eq "myaccount"
    end

    it "parses a SAS connection string with an explicit endpoint" do
      parsed = ConnectionString.parse("BlobEndpoint=https://myaccount.blob.core.windows.net/;SharedAccessSignature=sv=2024-11-04&sig=abc%3D")

      parsed.blob_endpoint.should eq URI.parse("https://myaccount.blob.core.windows.net/")
      parsed.credential.should be_a SASCredential
    end

    it "parses the development storage shortcut" do
      parsed = ConnectionString.parse("UseDevelopmentStorage=true")

      parsed.blob_endpoint.should eq URI.parse("http://127.0.0.1:10000/devstoreaccount1")
      parsed.credential.as(SharedKeyCredential).account_name.should eq "devstoreaccount1"
    end

    it "raises without an account or endpoint" do
      expect_raises ArgumentError do
        ConnectionString.parse("AccountKey=abc")
      end
    end
  end
end
