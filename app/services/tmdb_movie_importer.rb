# frozen_string_literal: true

require 'concurrent'
require 'fileutils'
require 'digest'
require_relative 'import_config'
require_relative 'tui'
require_relative 'pretty_logger'
require_relative 'tmdb_client'
require_relative 'database_service'
require_relative 'media_info_parser'

class TMDBMovieImporter
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
    PrettyLogger.info 'Fetching existing movie library from database...'
    existing_paths = @db_service.get_existing_file_paths
    PrettyLogger.info "Scanning '#{directory}' for new movie files..."
    video_extensions = '{mkv,mp4,mov,avi,m2ts}'
    all_files = Dir.glob(File.join(directory, '**', "*.#{video_extensions}"), File::FNM_CASEFOLD).sort
    movies_to_process = all_files.reject { |file| existing_paths.include?(File.absolute_path(file)) }
    display_scan_summary(all_files.length, movies_to_process.length)
    return if movies_to_process.empty?

    TUI.start(movies_to_process.length)
    movies_to_process.each do |file_path|
      process_movie_file(file_path)
      sleep(0.1)
    end
    TUI.finish
  end

  def shutdown
    return if @shutdown_started

    @shutdown_started = true
    PrettyLogger.info 'Waiting for background tasks to complete...'
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(600)
    @db_update_queue.close
    @db_updater_thread.join if @db_updater_thread.alive?
    @db_service.close
    PrettyLogger.success 'All background tasks finished and connections closed.'
  end

  private

  def process_movie_file(file_path)
    filename = File.basename(file_path)
    TUI.increment(filename)
    parsed_info = parse_filename(filename)
    unless parsed_info
      PrettyLogger.error("Could not parse movie info from filename: #{filename}")
      return
    end
    details = fetch_movie_details(parsed_info)
    unless details
      PrettyLogger.error("Could not find TMDB details for: #{parsed_info[:name]} (#{parsed_info[:year]})")
      return
    end
    @db_service.conn.transaction do
      movie_id = @db_service.insert_movie(details)
      @db_service.bulk_import_associations(movie_id, details)
      process_technical_data(movie_id, file_path)
      enqueue_image_downloads(movie_id, details)
    end
  rescue StandardError => e
    PrettyLogger.error("Fatal error processing '#{filename}': #{e.message}")
    PrettyLogger.debug(e.backtrace.join("\n"))
  end

  def parse_filename(filename)
    base = File.basename(filename, '.*')
    if (match = base.match(/^(.+?)\s\((\d{4})\)\s\(tmdbid-(\d+)\)$/i))
      { name: match[1].strip, year: match[2].to_i, tmdb_id: match[3].to_i }
    elsif (match = base.match(/^(.+?)\s*\((\d{4})\)/))
      { name: match[1].gsub('.', ' ').strip, year: match[2].to_i }
    end
  end

  def fetch_movie_details(parsed_info)
    if parsed_info[:tmdb_id]
      @tmdb_client.get_movie_details(parsed_info[:tmdb_id])
    else
      results = @tmdb_client.search_movie(parsed_info[:name], parsed_info[:year])
      return nil if results.empty?

      chosen_movie = results.length == 1 ? results.first : present_search_choices(results, parsed_info[:name])
      return nil unless chosen_movie

      @tmdb_client.get_movie_details(chosen_movie['id'])
    end
  end

  def process_technical_data(movie_id, file_path)
    mediainfo = MediaInfoParser.new(file_path)
    unless mediainfo.valid?
      PrettyLogger.warn("Could not read mediainfo for: #{File.basename(file_path)}")
      return
    end
    file_id = @db_service.insert_movie_file(movie_id, file_path, mediainfo)
    enqueue_checksum_calculation(file_id, file_path) if file_id
  end

  def enqueue_image_downloads(movie_id, details)
    images = details['images']
    return unless images

    poster = find_best_image(images['posters'], details['original_language'])
    backdrop = find_best_image(images['backdrops'], details['original_language'], :backdrop)
    logo = find_best_image(images['logos'], details['original_language'])
    enqueue_download(:movies, :poster_path, movie_id, poster&.dig('file_path'), "movies/#{movie_id}/poster.jpg")
    enqueue_download(:movies, :backdrop_path, movie_id, backdrop&.dig('file_path'), "movies/#{movie_id}/backdrop.jpg")
    enqueue_download(:movies, :logo_path, movie_id, logo&.dig('file_path'), "movies/#{movie_id}/logo.png")
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

  def enqueue_checksum_calculation(file_id, file_path)
    @thread_pool.post do
      digest = Digest::SHA256.new
      File.open(file_path, 'rb') do |file|
        while (chunk = file.read(1024 * 1024))
          digest.update(chunk)
        end
      end
      checksum = digest.hexdigest
      @db_update_queue << { table: :movie_files, id_col: :file_id, id_val: file_id,
                            data: { checksum_sha256: checksum } }
    rescue StandardError => e
      PrettyLogger.warn("Failed to calculate checksum for #{File.basename(file_path)}: #{e.message}")
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
    %w[movies people].each { |subdir| FileUtils.mkdir_p(File.join(MEDIA_BASE_DIR, subdir)) }
  end

  def display_scan_summary(total, to_process)
    puts '---------------------------'
    PrettyLogger.info "Scan Complete: Found #{total} movie files."
    PrettyLogger.success "  - #{total - to_process} movies are already in the database."
    PrettyLogger.info "  - #{to_process} new movies will be imported."
    puts '---------------------------'
  end

  def find_best_image(images, lang, _type = :poster)
    return nil if images.nil? || images.empty?

    images.find { |i| i['iso_639_1'] == lang } ||
      images.find { |i| i['iso_639_1'] == 'en' } ||
      images.find { |i| i['iso_639_1'].nil? } ||
      images.first
  end

  def present_search_choices(results, query)
    puts "\n\e[33mMultiple matches found for '#{query}'. Please choose:\e[0m"
    choices = results.first(8)
    choices.each_with_index do |movie, i|
      puts "  \e[32m[#{i + 1}]\e[0m #{movie['title']} (#{movie['release_date']&.slice(0, 4)})"
    end
    puts "  \e[32m[0]\e[0m Skip this movie"
    loop do
      print "Enter your choice (0-#{choices.length}): "
      choice = $stdin.gets.to_i
      return nil if choice.zero?
      return choices[choice - 1] if choice.between?(1, choices.length)

      puts "\e[31mInvalid choice. Please try again.\e[0m"
    end
  end
end
