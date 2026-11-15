module ProjectFiles
  # No to_path: Rack must not offload a temporary file before it is removed.
  class ArchiveBody
    def initialize(file)
      @file = file
    end

    def each
      File.open(@file.path, 'rb') do |input|
        while (chunk = input.read(64 * 1024))
          yield chunk
        end
      end
    ensure
      close
    end

    def close
      @file.close! if @file
      @file = nil
    end
  end
end
