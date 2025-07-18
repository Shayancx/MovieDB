# frozen_string_literal: true

require_relative 'import_config'
require_relative 'tmdb_client'
require_relative 'database_service'
require_relative 'pretty_logger'

class TMDBSeriesImporter
  include ImportConfig

  def initialize
    @db_service = DatabaseService.new
    @tmdb_client = TmdbClient.new
  end

  def import_from_directory(directory)
    dirs = Dir.children(directory).map { |d| File.join(directory, d) }
            .select { |p| File.directory?(p) }
    dirs.each do |dir|
      parsed = parse_dir_name(File.basename(dir))
      next unless parsed
      details = fetch_series_details(parsed)
      next unless details
      @db_service.conn.transaction do
        series_id = @db_service.insert_series(details)
        @db_service.bulk_import_series_associations(series_id, details)
      end
      PrettyLogger.success("Imported series #{details['name']}")
    end
  end

  def shutdown
    @db_service.close
  end

  private

  def parse_dir_name(name)
    if (m = name.match(/^(.*) \(tmdbid-(\d+)\)$/i))
      { name: m[1].strip, tmdb_id: m[2].to_i }
    else
      { name: name.gsub('.', ' ').strip }
    end
  end

  def fetch_series_details(info)
    if info[:tmdb_id]
      @tmdb_client.get_series_details(info[:tmdb_id])
    else
      results = @tmdb_client.search_series(info[:name], nil)
      return nil if results.empty?
      chosen = results.first
      @tmdb_client.get_series_details(chosen['id'])
    end
  end
end
