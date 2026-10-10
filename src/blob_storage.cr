require "./version"
require "./blob_storage/client"

# Client for [Azure Blob Storage](https://learn.microsoft.com/en-us/rest/api/storageservices/blob-service-rest-api).
#
# ```
# require "azure/blob_storage"
#
# blobs = Azure::BlobStorage::Client.from_connection_string(ENV["AZURE_STORAGE_CONNECTION_STRING"])
#
# File.open "report.pdf" do |file|
#   blobs.upload "reports", "2026/report.pdf", file, content_type: "application/pdf"
# end
#
# if properties = blobs.properties("reports", "2026/report.pdf")
#   properties.content_length # => 123456
#   properties.metadata       # => {"author" => "jamie"}
# end
#
# blobs.get "reports", "2026/report.pdf" do |io|
#   File.open("report.pdf", "w") { |file| IO.copy io, file }
# end
# ```
module Azure::BlobStorage
end
