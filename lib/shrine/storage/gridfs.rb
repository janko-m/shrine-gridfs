require "shrine"
require "mongo"
require "down"

require "stringio"

class Shrine
  module Storage
    class Gridfs
      attr_reader :client, :prefix, :bucket

      def initialize(client:, prefix: "fs", **options)
        @client = client
        @prefix = prefix
        @bucket = @client.database.fs(bucket_name: @prefix)
        @bucket.send(:ensure_indexes!)
      end

      def upload(io, id, shrine_metadata: {}, **upload_options)
        filename = shrine_metadata["filename"] || id
        file = Mongo::Grid::File.new(io, filename: filename, metadata: shrine_metadata)
        result = bucket.insert_one(file)
        id.replace(result.to_s + File.extname(id))
      end

      def download(id)
        Down.copy_to_tempfile(id, open(id))
      end

      def open(id)
        content_length = bucket.find(_id: bson_id(id)).first["length"]
        stream = bucket.open_download_stream(bson_id(id))

        Down::ChunkedIO.new(
          size: content_length,
          chunks: stream.enum_for(:each),
          on_close: -> { stream.close },
        )
      end

      def read(id)
        bucket.find_one(_id: bson_id(id)).data
      end

      def exists?(id)
        !!bucket.find(_id: bson_id(id)).first
      end

      def delete(id)
        bucket.delete(bson_id(id))
      end

      def multi_delete(ids)
        ids = ids.map { |id| bson_id(id) }
        bucket.files_collection.find(_id: {"$in" => ids}).delete_many
        bucket.chunks_collection.find(files_id: {"$in" => ids}).delete_many
      end

      def url(id, **options)
      end

      def clear!
        bucket.files_collection.find.delete_many
        bucket.chunks_collection.find.delete_many
      end

      def method_missing(name, *args)
        if name == :stream
          warn "Shrine::Storage::Gridfs#stream is deprecated over calling #each_chunk on result of Gridfs#open."
          content_length = bucket.find(_id: bson_id(*args)).first["length"]
          bucket.open_download_stream(bson_id(*args)) do |stream|
            stream.each { |chunk| yield chunk, content_length }
          end
        end
      end

      private

      def bson_id(id)
        BSON::ObjectId(File.basename(id, ".*"))
      end
    end
  end
end
