# frozen_string_literal: true

require 'concurrent'
require 'fileutils'
require_relative 'import_config'
require_relative 'tmdb_client'
require_relative 'database_service'
require_relative 'pretty_logger'

class TMDBSeriesImporter
  include ImportConfig

  def initialize
    @db_service = DatabaseService.new
    @tmdb_client = TmdbClient.new
    @thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: MAX_BG_THREADS,
      max_queue: MAX_BG_THREADS * 2,
      fallback_policy: :caller_runs
    )
    @db_update_queue = Queue.new
    @db_updater_thread = Thread.new { process_db_updates }
    setup_media_directories
  end

  def import_from_directory(directory)
    dirs = Dir.children(directory).map { |d| File.join(directory, d) }
            .select { |p| File.directory?(p) }
    dirs.each do |dir|
      parsed = parse_dir_name(File.basename(dir))
      next unless parsed
      details = fetch_series_details(parsed)
      next unless details
      series_id = nil
      people_map = nil
      @db_service.conn.transaction do
        series_id = @db_service.insert_series(details)
        people_map = @db_service.bulk_import_series_associations(series_id, details)
      end
      enqueue_series_image_downloads(series_id, details)
      enqueue_person_image_downloads(details, people_map)
      PrettyLogger.success("Imported series #{details['name']}")
    end
  end

  def shutdown
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(600)
    @db_update_queue.close
    @db_updater_thread.join if @db_updater_thread.alive?
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

  def enqueue_series_image_downloads(series_id, details)
    images = details['images']
    return unless images

    poster = find_best_image(images['posters'], details['original_language'])
    backdrop = find_best_image(images['backdrops'], details['original_language'], :backdrop)
    logo = find_best_image(images['logos'], details['original_language'])
    enqueue_download(:series, :poster_path, series_id, poster&.dig('file_path'), "series/#{series_id}/poster.jpg")
    enqueue_download(:series, :backdrop_path, series_id, backdrop&.dig('file_path'), "series/#{series_id}/backdrop.jpg")
    enqueue_download(:series, :logo_path, series_id, logo&.dig('file_path'), "series/#{series_id}/logo.png")
  end

  def enqueue_person_image_downloads(details, people_map)
    cast = details.dig('aggregate_credits', 'cast') || []
    crew = details.dig('aggregate_credits', 'crew') || []
    (cast + crew).uniq { |p| p['id'] }.each do |person|
      person_id = people_map[person['id']]
      next unless person_id && person['profile_path']

      enqueue_download(:people, :headshot_path, person_id, person['profile_path'], "people/#{person_id}/headshot.jpg")
    end
  end

  def enqueue_download(table, column, id, api_path, save_path)
    return unless api_path

    @thread_pool.post do
      relative_path = @tmdb_client.download_image(api_path, save_path)
      if relative_path
        id_col_name = "#{table.to_s.chomp('s')}_id"
        @db_update_queue << { table: table, id_col: id_col_name, id_val: id,
                              data: { column => File.basename(relative_path) } }
      end
    end
  end

  def process_db_updates
    while (update_job = @db_update_queue.pop)
      begin
        @db_service.update_record(**update_job)
      rescue StandardError => e
        PrettyLogger.error("Unexpected error in DB updater thread: #{e.message}")
      end
    end
  end

  def setup_media_directories
    %w[movies people series].each do |subdir|
      FileUtils.mkdir_p(File.join(MEDIA_BASE_DIR, subdir))
    end
  end

  def find_best_image(images, lang, _type = :poster)
    return nil if images.nil? || images.empty?

    images.find { |i| i['iso_639_1'] == lang } ||
      images.find { |i| i['iso_639_1'] == 'en' } ||
      images.find { |i| i['iso_639_1'].nil? } ||
      images.first
  end
end
