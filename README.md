# azure

A Crystal client for Microsoft Azure services.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     azure:
       github: jgaskins/azure
   ```

2. Run `shards install`

## Usage

### Blob Storage

```crystal
require "azure/blob_storage"

# Connection string from "Access keys" in the Azure portal. Also accepts
# SAS connection strings and "UseDevelopmentStorage=true" for Azurite.
blobs = Azure::BlobStorage::Client.from_connection_string(ENV["AZURE_STORAGE_CONNECTION_STRING"])

# Or with an account name and key directly
blobs = Azure::BlobStorage::Client.new(
  account_name: "mystorageaccount",
  account_key: ENV["AZURE_STORAGE_ACCOUNT_KEY"],
)

# Or as a service principal (Microsoft Entra ID app registration). It needs a
# data role like "Storage Blob Data Contributor" on the account or container.
blobs = Azure::BlobStorage::Client.new(
  account_name: "mystorageaccount",
  credential: Azure::BlobStorage::ClientSecretCredential.new(
    tenant_id: ENV["AZURE_TENANT_ID"],
    client_id: ENV["AZURE_CLIENT_ID"],
    client_secret: ENV["AZURE_CLIENT_SECRET"],
  ),
)
```

#### Uploading

`upload` accepts a `String`, `Bytes`, or any `IO`. Files up to 256MiB are sent in a single request; larger files and `IO`s of unknown size (like pipes) are streamed in 8MiB blocks, so they're never fully loaded into memory. Both thresholds are configurable with `max_single_upload_size` and `block_size` when creating the client.

```crystal
File.open "photo.jpg" do |file|
  blobs.upload "photos", "2026/10/photo.jpg", file,
    content_type: "image/jpeg",
    cache_control: "public, max-age=86400",
    metadata: {"uploaded_by" => "jamie"}
end

# Raise Azure::BlobStorage::RequestError (code "BlobAlreadyExists") instead of replacing
blobs.upload "notes", "todo.txt", "buy milk", overwrite: false
```

#### Properties and metadata

```crystal
if properties = blobs.properties("photos", "2026/10/photo.jpg")
  properties.content_length # => 482113
  properties.content_type   # => "image/jpeg"
  properties.last_modified  # => 2026-10-09 18:59:36 UTC
  properties.etag           # => "\"0x8DD...\""
  properties.metadata       # => {"uploaded_by" => "jamie"}
end

blobs.metadata("photos", "2026/10/photo.jpg") # => {"uploaded_by" => "jamie"}
```

Both return `nil` if the blob doesn't exist.

#### Downloading

```crystal
# Into memory
blobs.get("notes", "todo.txt") # => "buy milk"

# Streaming, for large or binary blobs
blobs.get "photos", "2026/10/photo.jpg" do |io, properties|
  File.open("photo.jpg", "w") { |file| IO.copy io, file }
end

# Part of a blob
blobs.get "logs", "app.log", range: 0...1024
```

`get` returns `nil` (and doesn't call the block) if the blob doesn't exist. Other errors raise `Azure::BlobStorage::RequestError`, which exposes the HTTP `status`, the Azure error `code`, and the `request_id`.

There are also `delete`, `create_container`, and `delete_container`.

## Development

The Blob Storage specs run against [Azurite](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite), and are marked pending if it isn't running:

```
docker run --rm -p 10000:10000 mcr.microsoft.com/azure-storage/azurite azurite-blob --blobHost 0.0.0.0
crystal spec spec/blob_storage
```

Set `AZURE_STORAGE_CONNECTION_STRING` to run them against a real storage account instead.

## Contributing

1. Fork it (<https://github.com/jgaskins/azure/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
