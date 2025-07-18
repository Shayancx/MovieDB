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

# Manages the import of movies from a directory into the database.
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
    @pending_tasks = Concurrent::AtomicFixnum.new(0)
    @shutdown_started = false
  end

  # Scans a directory for movie files and imports new ones.
  def import_from_directory(directory)
    setup_media_directories
    movie_files = find_movie_files(directory)
    existing_paths = @db_service.get_existing_file_paths
    movies_to_process = movie_files.reject { |file| existing_paths.include?(File.absolute_path(file)) }

    display_scan_summary(movie_files.length, movies_to_process.length)
    return if movies_to_process.empty?

    process_files(movies_to_process)
  end

  # Shuts down the importer, waiting for all background tasks to complete.
  def shutdown
    return if @shutdown_started
    @shutdown_started = true

    PrettyLogger.info 'Waiting for background tasks to complete...'
    
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(30)

    @db_update_queue.close
    @db_updater_thread.join if @db_updater_thread&.alive?
    @db_service.close
    PrettyLogger.success 'All background tasks finished and connections closed.'
  end

  private

  # Finds all video files in a directory.
  def find_movie_files(directory)
    video_extensions = '{mkv,mp4,mov,avi,m2ts}'
    Dir.glob(File.join(directory, '**', "*.#{video_extensions}"), File::FNM_CASEFOLD).sort
  rescue Errno::EACCES => e
    PrettyLogger.error("Permission denied while scanning directory: #{e.message}")
    []
  end

  # Processes a list of movie files.
  def process_files(files)
    TUI.start(files.length)
    files.each { |file_path| process_movie_file(file_path) }
    TUI.finish
    wait_for_pending_tasks(300) # Wait longer for all tasks after TUI finishes
  end

  # Full import process for a single movie file.
  def process_movie_file(file_path)
    TUI.increment(File.basename(file_path))
    parsed_info = parse_filename(File.basename(file_path))
    unless parsed_info
      PrettyLogger.error("Could not parse movie info from: #{File.basename(file_path)}")
      return
    end

    details = fetch_movie_details(parsed_info)
    unless details
      PrettyLogger.error("Could not find TMDB details for: #{parsed_info[:name]}")
      return
    end

    import_movie(details, file_path)
  rescue StandardError => e
    PrettyLogger.error("Fatal error processing '#{File.basename(file_path)}': #{e.message}")
    PrettyLogger.debug(e.backtrace.join("\n"))
  end

  # Handles the database insertion and media processing for a movie.
  def import_movie(details, file_path)
    movie_id = @db_service.insert_movie(details)
    return unless movie_id

    people_map = @db_service.bulk_import_associations(movie_id, details)
    process_technical_data(movie_id, file_path)
    enqueue_all_image_downloads(movie_id, details, people_map)
  end

  # Parses the movie title, year, and optional TMDB ID from a filename.
  def parse_filename(filename)
    base = File.basename(filename, '.*')
    if (match = base.match(/^(.+?)\s\((\d{4})\)\s\(tmdbid-(\d+)\)$/i))
      { name: match[1].strip.gsub('.', ' '), year: match[2].to_i, tmdb_id: match[3].to_i }
    elsif (match = base.match(/^(.+?)\s*\((\d{4})\)/))
      { name: match[1].strip.gsub('.', ' '), year: match[2].to_i }
    end
  end

  # Fetches movie details from TMDB, handling search and selection if needed.
  def fetch_movie_details(parsed_info)
    if parsed_info[:tmdb_id]
      return @tmdb_client.get_movie_details(parsed_info[:tmdb_id])
    end

    results = @tmdb_client.search_movie(parsed_info[:name], parsed_info[:year])
    return nil if results.empty?

    chosen_movie = results.length == 1 ? results.first : present_search_choices(results, parsed_info[:name])
    return nil unless chosen_movie

    @tmdb_client.get_movie_details(chosen_movie['id'])
  end

  # Processes mediainfo and enqueues checksum calculation.
  def process_technical_data(movie_id, file_path)
    mediainfo = MediaInfoParser.new(file_path)
    return unless mediainfo.valid?

    file_id = @db_service.insert_movie_file(movie_id, file_path, mediainfo)
    enqueue_checksum_calculation(file_id, file_path) if file_id
  end

  # Enqueues downloads for movie and person images.
  def enqueue_all_image_downloads(movie_id, details, people_map)
    enqueue_movie_image_downloads(movie_id, details)
    enqueue_person_image_downloads(details, people_map) if people_map
  end

  def enqueue_movie_image_downloads(movie_id, details)
    images = details['images']
    return unless images

    {
      poster: find_best_image(images['posters'], details['original_language']),
      backdrop: find_best_image(images['backdrops'], details['original_language']),
      logo: find_best_image(images['logos'], details['original_language'])
    }.each do |type, image|
      next unless image
      save_path = "movies/#{movie_id}/#{type}#{File.extname(image['file_path'])}"
      enqueue_download(:movies, "#{type}_path", movie_id, image['file_path'], save_path)
    end
  end

  def enqueue_person_image_downloads(details, people_map)
    (details.dig('credits', 'cast') || []).each do |person|
      person_id = people_map[person['id']]
      next unless person_id && person['profile_path']
      save_path = "people/#{person_id}/headshot#{File.extname(person['profile_path'])}"
      enqueue_download(:people, :headshot_path, person_id, person['profile_path'], save_path)
    end
  end

  # Generic method to enqueue a download and subsequent DB update.
  def enqueue_download(table, column, id, api_path, save_path)
    return if api_path.blank?
    @pending_tasks.increment
    @thread_pool.post do
      begin
        if @tmdb_client.download_image(api_path, save_path)
          @db_update_queue << { table: table, id: id, data: { column => File.basename(save_path) } }
        end
      ensure
        @pending_tasks.decrement
      end
    end
  end

  # Enqueues a background job to calculate the file's checksum.
  def enqueue_checksum_calculation(file_id, file_path)
    @pending_tasks.increment
    @thread_pool.post do
      begin
        checksum = Digest::SHA256.file(file_path).hexdigest
        @db_update_queue << { table: :movie_files, id: file_id, data: { checksum_sha256: checksum } }
      rescue StandardError => e
        PrettyLogger.warn("Failed to calculate checksum for #{File.basename(file_path)}: #{e.message}")
      ensure
        @pending_tasks.decrement
      end
    end
  end

  # The loop that processes database updates from the queue.
  def process_db_updates
    while (update_job = @db_update_queue.pop)
      @db_service.update_record(update_job[:table], update_job[:id], update_job[:data])
    end
  rescue StandardError => e
    PrettyLogger.error("DB updater thread crashed: #{e.message}") unless @db_update_queue.closed?
  end

  # Creates the necessary media directories.
  def setup_media_directories
    %w[movies people series].each do |subdir|
      FileUtils.mkdir_p(File.join(MEDIA_BASE_DIR, subdir))
    end
  end

  # Displays a summary of the file scan.
  def display_scan_summary(total, to_process)
    new_count_str = "#{to_process} new movie#{to_process == 1 ? '' : 's'}"
    PrettyLogger.info "Scan Complete: Found #{total} movie files."
    PrettyLogger.info "  - #{new_count_str} to be imported."
  end

  # Finds the best image from a list based on language preference.
  def find_best_image(images, lang)
    return nil if images.blank?
    images.find { |i| i['iso_639_1'] == lang } ||
      images.find { |i| i['iso_639_1'] == 'en' } ||
      images.find { |i| i['iso_639_1'].nil? } ||
      images.first
  end

  # Prompts the user to choose from multiple search results.
  def present_search_choices(results, query)
    # Implementation for user interaction
  end

  # Waits for all pending background tasks to complete.
  def wait_for_pending_tasks(timeout)
    start_time = Time.now
    while @pending_tasks.value > 0 && (Time.now - start_time) < timeout
      sleep(0.1)
    end
    if @pending_tasks.value > 0
      PrettyLogger.warn("Timed out waiting for #{@pending_tasks.value} tasks.")
    end
  end
end

# Ensure shutdown is called on exit
at_exit do
  ObjectSpace.each_object(TMDBMovieImporter) do |importer|
    importer.shutdown unless importer.instance_variable_get(:@shutdown_started)
  end
end
