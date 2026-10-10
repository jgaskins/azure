require "spec"
require "../../src/blob_storage"
require "socket"

# These specs run against Azurite, the Azure Storage emulator:
#
#   docker run --rm -p 10000:10000 mcr.microsoft.com/azure-storage/azurite azurite-blob --blobHost 0.0.0.0
#
# Set AZURE_STORAGE_CONNECTION_STRING to run them against a real storage account.
connection_string = ENV.fetch("AZURE_STORAGE_CONNECTION_STRING", "UseDevelopmentStorage=true")
endpoint = Azure::BlobStorage::ConnectionString.parse(connection_string).blob_endpoint
available = begin
  TCPSocket.new(endpoint.host.not_nil!, endpoint.port || (endpoint.scheme == "https" ? 443 : 80), connect_timeout: 1.second).close
  true
rescue Socket::Error | IO::TimeoutError
  false
end

module Azure::BlobStorage
  describe Client do
    unless available
      pending "requires Azurite or AZURE_STORAGE_CONNECTION_STRING (no Blob service at #{endpoint})"
      next
    end

    # Small sizes so we can exercise multi-block uploads cheaply
    client = Client.from_connection_string(connection_string,
      max_single_upload_size: 1024,
      block_size: 256,
    )
    container = "spec-#{Random::Secure.hex(6)}"

    before_all { client.create_container container }
    after_all { client.delete_container container }

    it "returns false when creating a container that exists" do
      client.create_container(container).should eq false
    end

    it "uploads a string and reads it back with its properties" do
      result = client.upload container, "dir/hello world.txt", "hello world",
        content_type: "text/plain",
        cache_control: "max-age=60",
        metadata: {"author" => "jamie", "Purpose" => "testing"}

      properties = client.properties(container, "dir/hello world.txt").should_not be_nil
      properties.content_length.should eq 11
      properties.content_type.should eq "text/plain"
      properties.cache_control.should eq "max-age=60"
      properties.etag.should eq result.etag
      properties.blob_type.should eq "BlockBlob"
      properties.metadata.should eq({"author" => "jamie", "Purpose" => "testing"})
      client.metadata(container, "dir/hello world.txt").should eq properties.metadata

      client.get(container, "dir/hello world.txt").should eq "hello world"
    end

    it "uploads binary data" do
      data = Random.new(42).random_bytes(500)
      client.upload container, "binary.bin", data

      client.get(container, "binary.bin", &.getb_to_end).should eq data
    end

    it "uploads a file larger than the single-upload limit in blocks" do
      data = Random.new(1).random_bytes(3000)
      File.tempfile("blob") do |file|
        file.write data
        file.rewind
        client.upload container, "large.bin", file, content_type: "application/octet-stream", metadata: {"size" => "3000"}
      end

      properties = client.properties(container, "large.bin").should_not be_nil
      properties.content_length.should eq 3000
      properties.content_type.should eq "application/octet-stream"
      properties.metadata.should eq({"size" => "3000"})
      client.get(container, "large.bin", &.getb_to_end).should eq data
    end

    it "uploads from an IO of unknown size" do
      data = "x" * 1000
      reader, writer = IO.pipe
      spawn { writer << data; writer.close }

      client.upload container, "piped.txt", reader
      client.get(container, "piped.txt").should eq data

      reader, writer = IO.pipe
      spawn { writer << "short"; writer.close }
      client.upload container, "piped-short.txt", reader
      client.get(container, "piped-short.txt").should eq "short"
    end

    it "uploads an empty blob" do
      client.upload container, "empty.txt", ""

      client.properties(container, "empty.txt").should_not(be_nil).content_length.should eq 0
      client.get(container, "empty.txt").should eq ""
    end

    it "gets a range of a blob" do
      client.upload container, "alphabet.txt", "abcdefghijklmnopqrstuvwxyz"

      client.get(container, "alphabet.txt", range: 2..4).should eq "cde"
      client.get(container, "alphabet.txt", range: 23..).should eq "xyz"
      client.get(container, "alphabet.txt", range: 0...3) do |io, properties|
        properties.content_length.should eq 26
        io.gets_to_end
      end.should eq "abc"
    end

    it "refuses to overwrite when asked not to" do
      client.upload container, "once.txt", "first"

      error = expect_raises RequestError do
        client.upload container, "once.txt", "second", overwrite: false
      end
      error.status.should eq HTTP::Status::CONFLICT
      error.code.should eq "BlobAlreadyExists"
      client.get(container, "once.txt").should eq "first"
    end

    it "returns nil for blobs that don't exist" do
      client.properties(container, "nope").should be_nil
      client.metadata(container, "nope").should be_nil
      client.get(container, "nope").should be_nil
      client.get(container, "nope") { raise "should not be called" }.should be_nil
    end

    it "deletes blobs" do
      client.upload container, "doomed.txt", "bye"

      client.delete(container, "doomed.txt").should eq true
      client.delete(container, "doomed.txt").should eq false
      client.get(container, "doomed.txt").should be_nil
    end

    it "raises on authentication failure" do
      bad = Client.new(
        endpoint: endpoint,
        credential: SharedKeyCredential.new(ConnectionString::DEVELOPMENT_ACCOUNT_NAME, Base64.strict_encode("wrong")),
      )

      error = expect_raises RequestError do
        bad.get(container, "anything")
      end
      error.status.should eq HTTP::Status::FORBIDDEN
      error.code.should eq "AuthorizationFailure"
    end
  end
end
