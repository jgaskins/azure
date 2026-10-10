require "uri"

module Azure::BlobStorage
  # Parses an Azure Storage [connection string](https://learn.microsoft.com/en-us/azure/storage/common/storage-configure-connection-string)
  # like the ones shown under "Access keys" in the Azure portal.
  struct ConnectionString
    # Well-known credentials for the [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite) emulator
    DEVELOPMENT_ACCOUNT_NAME = "devstoreaccount1"
    DEVELOPMENT_ACCOUNT_KEY  = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

    getter blob_endpoint : URI
    getter credential : Credential?

    def self.parse(string : String) : self
      new string
    end

    def initialize(string : String)
      values = Hash(String, String).new
      string.split(';', remove_empty: true).each do |pair|
        key, _, value = pair.partition('=')
        values[key.strip] = value.strip
      end

      if values["UseDevelopmentStorage"]?.try(&.downcase) == "true"
        proxy = values["DevelopmentStorageProxyUri"]? || "http://127.0.0.1"
        uri = URI.parse(proxy)
        @blob_endpoint = URI.parse("#{uri.scheme}://#{uri.host}:10000/#{DEVELOPMENT_ACCOUNT_NAME}")
        @credential = SharedKeyCredential.new(DEVELOPMENT_ACCOUNT_NAME, DEVELOPMENT_ACCOUNT_KEY)
        return
      end

      account_name = values["AccountName"]?
      if endpoint = values["BlobEndpoint"]?
        @blob_endpoint = URI.parse(endpoint)
      elsif account_name
        protocol = values["DefaultEndpointsProtocol"]? || "https"
        suffix = values["EndpointSuffix"]? || "core.windows.net"
        @blob_endpoint = URI.parse("#{protocol}://#{account_name}.blob.#{suffix}")
      else
        raise ArgumentError.new("Connection string must contain AccountName or BlobEndpoint")
      end

      if account_name && (account_key = values["AccountKey"]?)
        @credential = SharedKeyCredential.new(account_name, account_key)
      elsif sas = values["SharedAccessSignature"]?
        @credential = SASCredential.new(sas)
      end
    end
  end
end
