#!/usr/bin/env ruby
# frozen_string_literal: true

# For this script to run, you need the 'pg' and 'concurrent-ruby' gems.
# You can install them with:
# gem install pg
# gem install concurrent-ruby

require 'pg'
require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'fileutils'
require 'set'
require 'open-uri'
require 'digest'
require 'concurrent'
require 'thread'

# --- CONFIGURATION ---
TMDB_API_KEY = ENV.fetch('TMDB_API_KEY', 'eb0e30eac4bf856683dbde0853e35bbb')
TMDB_API_BASE_URL = 'https://api.themoviedb.org/3'
TMDB_IMAGE_BASE_URL = 'https://image.tmdb.org/t/p/original'
MEDIA_BASE_DIR = File.join(Dir.home, 'Dokumente', 'MovieDB', 'media')
MAX_BG_THREADS = ENV.fetch('MAX_BG_THREADS', 5).to_i

# --- PRETTY LOGGER ---
class PrettyLogger
  @@errors = []
  @@warnings = []
  
  def self.info(msg)
    puts "[\e[34mINFO\e[0m] #{msg}"
  end

  def self.warn(msg)
    @@warnings << msg
    if TUI.active?
      # Store warning for later display
    else
      puts "\n[\e[33mWARN\e[0m] #{msg}"
    end
  end

  def self.error(msg)
    @@errors << msg
    if TUI.active?
      # Store error for later display
    else
      puts "\n[\e[31mERROR\e[0m] #{msg}"
    end
  end

  def self.success(msg)
    puts "[\e[32mSUCCESS\e[0m] #{msg}"
  end

  def self.debug(msg)
    puts "[\e[35mDEBUG\e[0m] #{msg}" if ENV['DEBUG']
  end
  
  def self.display_accumulated
    if @@warnings.any?
      puts "\n[\e[33mWarnings:\e[0m]"
      @@warnings.each { |w| puts "  • #{w}" }
    end
    
    if @@errors.any?
      puts "\n[\e[31mErrors:\e[0m]"
      @@errors.each { |e| puts "  • #{e}" }
    end
    
    @@warnings.clear
    @@errors.clear
  end
  
  def self.error_count
    @@errors.length
  end
  
  def self.warning_count
    @@warnings.length
  end
end

# --- TERMINAL UI CLASS ---
class TUI
  @@active = false
  
  def self.active?
    @@active
  end
  
  def self.start(total)
    @@active = true
    @total = total
    @count = 0
    @start_time = Time.now
    @processed_movies = []
    puts "\n"
    update_progress
    update_status("Initializing...")
  end

  def self.increment(name)
    @count += 1
    @processed_movies << name
    update_progress
    update_status(name)
  end

  def self.finish
    return unless @@active && @start_time # Guard against finishing if not started
    @@active = false
    
    @count = @total if @count < @total
    update_progress
    elapsed = Time.now - @start_time
    update_status("Import finished in #{format_duration(elapsed)}.")
    puts "\n"
    
    # Display accumulated errors and warnings
    PrettyLogger.display_accumulated
  end

  private

  def self.format_duration(seconds)
    minutes = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    "#{minutes}m #{secs}s"
  end

  def self.update_progress
    bar_length = 30
    percent = @total > 0 ? (@count.to_f / @total) : 1.0
    filled_length = (bar_length * percent).to_i
    bar = "\e[32m" + '█' * filled_length + "\e[0m" + ' ' * (bar_length - filled_length)
    
    elapsed = Time.now - @start_time
    eta = if @count > 0 && @count < @total
      remaining = (@total - @count) * (elapsed / @count)
      " - ETA: #{format_duration(remaining)}"
    else
      ""
    end
    
    # Move cursor up 2 lines, clear line, print progress, then move to next line
    print "\e[2A\e[K"
    puts "  \e[36mProcessing\e[0m [#{bar}] #{@count}/#{@total} (#{(percent * 100).to_i}%)#{eta}"
  end

  def self.update_status(name)
    print "\e[K" # Clear the current line
    puts "  \e[2m└─ Currently:\e[0m #{name}"
  end
end

# --- ENUM MAPPERS ---
class EnumMapper
  FILE_FORMAT_MAP = {
    'mkv' => 'MKV', 'mp4' => 'MP4', 'mov' => 'MOV', 'avi' => 'AVI', 'm2ts' => 'M2TS'
  }.freeze
  SUBTITLE_FORMAT_MAP = {
    'srt' => 'SRT', 'subrip' => 'SRT', 'utf-8' => 'SRT', 'utf8' => 'SRT', 'ass' => 'ASS',
    'ssa' => 'ASS', 'pgs' => 'PGS', 'vobsub' => 'VOBSUB', 'vob' => 'VOBSUB'
  }.freeze
  ASPECT_RATIO_MAP = {
    '1.33:1' => '1.33', '4:3' => '1.33', '1.37:1' => '1.33', '1.66:1' => '1.66',
    '1.78:1' => '1.78', '16:9' => '1.78', '1.85:1' => '1.85', '2.00:1' => '2.00',
    '2.20:1' => '2.20', '2.35:1' => '2.35', '2.39:1' => '2.39', '2.40:1' => '2.39'
  }.freeze
  AUDIO_CHANNELS_MAP = {
    '1' => 'Mono', '1.0' => 'Mono', 'mono' => 'Mono', '2' => 'Stereo', '2.0' => 'Stereo',
    'stereo' => 'Stereo', '3' => '2.1', '2.1' => '2.1', '4' => '4.0', '4.0' => '4.0',
    '6' => '5.1', '5.1' => '5.1', '7' => '6.1', '6.1' => '6.1', '8' => '7.1',
    '7.1' => '7.1', 'atmos' => 'Atmos', 'dolby atmos' => 'Atmos', 'dts:x' => 'DTS:X'
  }.freeze

  def self.normalize_aspect_ratio(ratio); ASPECT_RATIO_MAP[ratio]; end
end

# --- MEDIAINFO JSON PARSER ---
class MediaInfoParser
  def initialize(json_content)
    @data = JSON.parse(json_content)
    @media = @data['media']
  rescue
    @media = nil
    PrettyLogger.warn "Failed to parse MediaInfo JSON content."
  end

  def valid?; !@media.nil?; end

  def track(type); (@media['track'] || []).find { |t| t['@type'] == type }; end
  def tracks(type); (@media['track'] || []).select { |t| t['@type'] == type }; end

  def general; @general ||= track('General'); end
  def video; @video ||= track('Video'); end
  def audio_tracks; @audio_tracks ||= tracks('Audio'); end
  def subtitle_tracks; @subtitle_tracks ||= tracks('Text'); end

  def file_format; general['Format']; end
  def duration_minutes; (general['Duration'].to_f / 60).round; end
  def file_size_mb; (general['FileSize'].to_f / 1024 / 1024).round; end

  def video_codec; video['Format']; end
  def video_bitrate_kbps; (video['BitRate'].to_f / 1000).round; end
  def frame_rate; video['FrameRate'].to_f.round(3); end
  def aspect_ratio; EnumMapper.normalize_aspect_ratio(video['DisplayAspectRatio']); end
  def width; video['Width'].to_i; end
  def height; video['Height'].to_i; end
end

# --- FILE UTILITIES ---
class MovieFileUtils
  def self.calculate_sha256(file_path, chunk_size = 1024 * 1024)
    digest = Digest::SHA256.new
    File.open(file_path, 'rb') do |file|
      while chunk = file.read(chunk_size)
        digest.update(chunk)
      end
    end
    digest.hexdigest
  rescue => e
    PrettyLogger.warn "Failed to calculate checksum for #{File.basename(file_path)}: #{e.message}"
    nil
  end

  def self.find_external_subtitles(movie_file_path)
    base_name = File.basename(movie_file_path, '.*')
    dir = File.dirname(movie_file_path)
    subtitle_extensions = %w[.srt .ass .ssa .vtt .sub .idx]
    subtitles = []
    subtitle_extensions.each do |ext|
      Dir.glob(File.join(dir, "#{base_name}*#{ext}")).each do |sub_file|
        lang_code = sub_file.match(/\.([a-z]{2,3})#{Regexp.escape(ext)}$/i) ? $1.downcase : nil
        subtitles << { file_path: sub_file, language_code: lang_code, format: ext[1..-1].upcase }
      end
    end
    subtitles
  end

  def self.guess_source_media_type(file_path)
    basename = File.basename(file_path).downcase
    case basename
    when /blu-?ray|bluray|bdremux|bdmux/i then 'Blu-ray'
    when /4k[\s\-.]?(?:uhd|blu-?ray|bluray)/i then '4K Blu-ray'
    when /dvd/i then 'DVD'
    when /web-?dl/i then 'Web-DL'
    when /web-?rip/i then 'WEB-Rip'
    else 'Digital'
    end
  end
end

# --- MAIN IMPORTER CLASS ---
class TMDBMovieImporter
  def initialize(db_config_file = 'database.yml')
    @db_config = load_db_config(db_config_file)
    @conn = connect_to_db
    setup_media_directories
    @http_client = setup_http_client

    @thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: MAX_BG_THREADS,
      max_queue: MAX_BG_THREADS * 2,
      fallback_policy: :caller_runs
    )
    
    @db_update_queue = Queue.new
    @db_updater_thread = Thread.new { process_db_updates }
  end

  def load_db_config(config_file)
    YAML.load_file(config_file)
  rescue Errno::ENOENT
    PrettyLogger.warn "Database config '#{config_file}' not found. Using defaults/ENV."
    {
      'host' => ENV['DB_HOST'] || 'localhost', 'port' => ENV['DB_PORT'] || 5432,
      'dbname' => ENV['DB_NAME'] || 'MovieDB', 'user' => ENV['DB_USER'] || ENV['USER'] || 'postgres',
      'password' => ENV['DB_PASSWORD'] || ''
    }
  end

  def connect_to_db
    PG.connect(@db_config)
  rescue PG::Error => e
    PrettyLogger.error "Failed to connect to database: #{e.message}"; raise
  end

  def setup_http_client
    uri = URI(TMDB_API_BASE_URL)
    http = Net::HTTP.new(uri.host, uri.port); http.use_ssl = true
    http.open_timeout = 10; http.read_timeout = 30; http
  end
  
  def setup_media_directories
    %w[movies people].each { |subdir| FileUtils.mkdir_p(File.join(MEDIA_BASE_DIR, subdir)) }
  end

  def shutdown
    return if @shutdown_started
    @shutdown_started = true
    
    PrettyLogger.info "Waiting for background tasks to complete..."
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(600)
    
    @db_update_queue.close
    @db_updater_thread.join if @db_updater_thread.alive?
    PrettyLogger.success "All background tasks finished."
  end

  def process_db_updates
    while (update_job = @db_update_queue.pop)
      begin
        sql = "UPDATE #{update_job[:table]} SET "
        sql += update_job[:data].keys.map.with_index { |k, i| "#{k} = $#{i + 1}" }.join(', ')
        sql += " WHERE #{update_job[:id_col]} = $#{update_job[:data].size + 1}"
        
        values = update_job[:data].values + [update_job[:id_val]]
        
        @conn.exec_params(sql, values)
        PrettyLogger.debug "DB updated for #{update_job[:table]} ##{update_job[:id_val]}"
      rescue PG::Error => e
        PrettyLogger.error "DB update failed for #{update_job[:table]} ##{update_job[:id_val]}: #{e.message}"
      rescue => e
        PrettyLogger.error "Unexpected error in DB updater thread: #{e.message}"
      end
    end
  end

  def import_movies_from_directory(directory)
    PrettyLogger.info "Fetching existing movie library from database..."
    existing_file_paths = @conn.exec("SELECT file_path FROM movie_files").map { |row| row['file_path'] }.to_set

    PrettyLogger.info "Scanning local movie directory for video files..."
    video_extensions = '{mkv,mp4,mov,avi,m2ts}'
    all_files = Dir.glob(File.join(directory, "**", "*.#{video_extensions}"), File::FNM_CASEFOLD).sort
    movies_to_process = all_files.reject { |file| existing_file_paths.include?(File.absolute_path(file)) }

    total_files = all_files.length
    already_imported_count = total_files - movies_to_process.length
    puts "---------------------------"
    PrettyLogger.info "Scan Complete: Found #{total_files} movie video files."
    PrettyLogger.success "  - #{already_imported_count} movies are already in the database (will be skipped)."
    PrettyLogger.info "  - #{movies_to_process.length} new movies will be imported."
    puts "---------------------------"

    return if movies_to_process.empty?
    
    TUI.start(movies_to_process.length)
    
    movies_to_process.each do |file_path|
      filename = File.basename(file_path)
      begin
        process_single_movie(file_path)
      rescue => e
        PrettyLogger.error "Fatal error processing '#{filename}': #{e.message}"
        PrettyLogger.debug e.backtrace.join("\n")
      end
      # The TMDB API has a rate limit of 40-50 requests per 10 seconds.
      # A small delay helps avoid hitting it during rapid-fire searches.
      sleep(0.1)
    end
    
    TUI.finish
  end

  def process_single_movie(file_path)
    filename = File.basename(file_path, '.*')
    
    if match = filename.match(/^(.+?)\s\((\d{4})\)\s\((\d+)\)$/)
      movie_name, year, tmdb_id = match[1].strip, match[2].to_i, match[3].to_i
      TUI.increment("#{movie_name} (#{year}) [TMDB ID]")
      import_movie_by_tmdb_id(tmdb_id, file_path)
    elsif match = filename.match(/^(.+?)\s*\((\d{4})\)/)
      movie_name, year = match[1].gsub('.', ' ').strip, match[2].to_i
      TUI.increment("SEARCHING: #{movie_name} (#{year})")
      import_movie_by_searching(movie_name, year, file_path)
    else
      TUI.increment("SKIPPING: #{filename}")
      PrettyLogger.error "Could not parse filename: #{filename}"
      return false
    end
  end

  def import_movie_by_tmdb_id(tmdb_id, video_file_path)
    details = get_tmdb_movie_details(tmdb_id)
    return false unless details

    @conn.transaction do |conn|
      movie_id = insert_movie_data(conn, details)
      bulk_import_associations(conn, movie_id, details)
      enqueue_movie_image_downloads(movie_id, details)
      populate_technical_data(conn, movie_id, video_file_path)
    end
    true
  rescue => e
    PrettyLogger.error "Failed to import TMDB ID #{tmdb_id}: #{e.message}"
    PrettyLogger.debug e.backtrace.join("\n")
    false
  end

  def import_movie_by_searching(name, year, file_path)
    results = search_tmdb_movie(name, year)
    if results.empty?
      PrettyLogger.error "Movie not found on TMDB: #{name} (#{year})"
      return false
    end
    
    tmdb_movie = results.length == 1 ? results.first : present_search_choices(results, name)
    return false unless tmdb_movie

    import_movie_by_tmdb_id(tmdb_movie['id'], file_path)
  end

  def make_api_request(path, params = {})
    params[:api_key] = TMDB_API_KEY
    uri = URI("#{TMDB_API_BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)
    
    request = Net::HTTP::Get.new(uri)
    response = @http_client.request(request)
    
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    when Net::HTTPTooManyRequests
      retry_after = response['Retry-After']&.to_i || 10
      PrettyLogger.warn "Rate limited. Waiting #{retry_after} seconds..."
      sleep(retry_after)
      make_api_request(path, params)
    else
      PrettyLogger.warn "API request failed for '#{path}': #{response.code} - #{response.message}"
      nil
    end
  end
  
  def search_tmdb_movie(name, year)
    # FIX: The API returns a hash with a 'results' key. Extract the array.
    response = make_api_request('/search/movie', { query: name, year: year }.compact)
    (response && response['results']) || []
  end
  
  def get_tmdb_movie_details(tmdb_id)
    make_api_request("/movie/#{tmdb_id}", append_to_response: 'credits,release_dates,images')
  end

  def insert_movie_data(conn, details)
    franchise_id = get_or_create_franchise(conn, details['belongs_to_collection'])
    
    sql = <<~SQL
      INSERT INTO movies (movie_name, original_title, release_date, description, runtime_minutes, imdb_id, tmdb_id, rating, franchise_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      ON CONFLICT (tmdb_id) DO UPDATE SET movie_name = EXCLUDED.movie_name
      RETURNING movie_id
    SQL
    
    result = conn.exec_params(sql, [
      details['title'], details['original_title'], details['release_date'],
      details['overview'], details['runtime'], details['imdb_id'], details['id'],
      details['vote_average']&.round(1), franchise_id
    ])
    result.first['movie_id'].to_i
  end

  def bulk_import_associations(conn, movie_id, details)
    # Genres
    genre_names = (details['genres'] || []).map { |g| g['name'] }
    genre_ids = get_or_create_bulk(conn, 'genres', 'genre_name', 'genre_id', genre_names)
    link_bulk(conn, 'movie_genres', 'movie_id', 'genre_id', movie_id, genre_ids)

    # Languages
    lang_data = (details['spoken_languages'] || []).map { |l| { code: l['iso_639_1'], name: l['english_name'] } }
    # Custom bulk methods for tables with more than one column
    lang_ids = get_or_create_languages_bulk(conn, lang_data)
    link_bulk(conn, 'movie_languages', 'movie_id', 'language_id', movie_id, lang_ids)

    # Countries
    country_data = (details['production_countries'] || []).map { |c| { code: c['iso_3166_1'], name: c['name'] } }
    country_ids = get_or_create_countries_bulk(conn, country_data)
    link_bulk(conn, 'movie_countries', 'movie_id', 'country_id', movie_id, country_ids)
    
    # People (Cast & Crew)
    cast_data = (details.dig('credits', 'cast') || []).first(50)
    crew_data = (details.dig('credits', 'crew') || [])
    people_data = (cast_data + crew_data).uniq { |p| p['id'] }
    people_ids_map = get_or_create_people_bulk(conn, people_data)

    link_cast_bulk(conn, movie_id, cast_data, people_ids_map)
    link_crew_bulk(conn, movie_id, crew_data, people_ids_map)
  end

  def get_or_create_bulk(conn, table, name_col, id_col, names)
    return [] if names.empty?
    
    sql_find = "SELECT #{name_col}, #{id_col} FROM #{table} WHERE #{name_col} = ANY($1::text[])"
    existing_map = conn.exec_params(sql_find, [names]).to_h { |row| [row[name_col], row[id_col]] }
    
    new_names = names.uniq - existing_map.keys
    
    if new_names.any?
      sql_insert = "INSERT INTO #{table} (#{name_col}) SELECT unnest($1::text[]) ON CONFLICT (#{name_col}) DO NOTHING RETURNING #{name_col}, #{id_col}"
      conn.exec_params(sql_insert, [new_names]).each do |row|
        existing_map[row[name_col]] = row[id_col]
      end
    end
    
    names.map { |name| existing_map[name] }.compact.uniq
  end
  
  def get_or_create_people_bulk(conn, people_data)
    return {} if people_data.empty?
    tmdb_ids = people_data.map { |p| p['id'] }.compact.uniq
    
    sql_find = "SELECT tmdb_person_id, person_id FROM people WHERE tmdb_person_id = ANY($1::int[])"
    people_map = conn.exec_params(sql_find, [tmdb_ids]).to_h { |r| [r['tmdb_person_id'].to_i, r['person_id']] }

    new_people_data = people_data.reject { |p| people_map.key?(p['id']) }

    if new_people_data.any?
      new_people_data.each_slice(100) do |slice|
          values_str = slice.map.with_index do |p, i|
            idx = i * 4
            "($#{idx + 1}, $#{idx + 2}, $#{idx + 3}, $#{idx + 4})"
          end.join(', ')
          
          values = slice.flat_map do |p|
            name_parts = p['name'].split(/\s+/, 2)
            [p['name'], name_parts[0], name_parts[1], p['id']]
          end

          sql_insert = "INSERT INTO people (full_name, first_name, last_name, tmdb_person_id) VALUES #{values_str} ON CONFLICT (tmdb_person_id) DO NOTHING RETURNING tmdb_person_id, person_id"
          conn.exec_params(sql_insert, values).each { |r| people_map[r['tmdb_person_id'].to_i] = r['person_id'] }
      end
    end
    
    people_data.each do |p_data|
      person_id = people_map[p_data['id']]
      if person_id && p_data['profile_path']
        enqueue_person_headshot_download(person_id, p_data['profile_path'])
      end
    end

    people_map
  end

  def link_bulk(conn, link_table, movie_id_col, other_id_col, movie_id, other_ids)
    return if other_ids.empty?
    values_str = other_ids.uniq.map.with_index { |_, i| "($1, $#{i + 2})" }.join(', ')
    sql = "INSERT INTO #{link_table} (#{movie_id_col}, #{other_id_col}) VALUES #{values_str} ON CONFLICT DO NOTHING"
    conn.exec_params(sql, [movie_id] + other_ids.uniq)
  end
  
  def link_cast_bulk(conn, movie_id, cast_data, people_map)
    cast_values = cast_data.map do |member|
        person_id = people_map[member['id']]
        next unless person_id && member['character']
        [movie_id, person_id, member['character'], member['order'] + 1]
    end.compact

    return if cast_values.empty?
    
    # FIX: The original code was missing the loop to feed data to put_copy_data.
    conn.copy_into('movie_cast', columns: %w[movie_id person_id character_name billing_order], format: :binary) do
        cast_values.each { |row| conn.put_copy_data(row) }
    end
  rescue PG::UniqueViolation
    # This can happen if re-running on a movie already processed in the same batch
    PrettyLogger.debug "Cast for movie ##{movie_id} already linked."
  end

  def link_crew_bulk(conn, movie_id, crew_data, people_map)
      directors = crew_data.select { |c| c['job'] == 'Director' }
      writers = crew_data.select { |c| ['Screenplay', 'Writer', 'Story'].include?(c['job']) }
      
      director_ids = directors.map { |d| people_map[d['id']] }.compact
      writer_ids = writers.map { |w| people_map[w['id']] }.compact
      
      link_bulk(conn, 'movie_directors', 'movie_id', 'person_id', movie_id, director_ids)
      link_bulk(conn, 'movie_writers', 'movie_id', 'person_id', movie_id, writer_ids)
  end

  def enqueue_movie_image_downloads(movie_id, details)
    images = details['images']
    return unless images

    best_poster = find_best_image(images['posters'], details['original_language'])
    best_backdrop = find_best_image(images['backdrops'], details['original_language'], :backdrop)
    best_logo = find_best_image(images['logos'], details['original_language'])
    
    enqueue_download(:movies, :poster_path, movie_id, best_poster&.dig('file_path'), "movies/#{movie_id}/poster.jpg")
    enqueue_download(:movies, :backdrop_path, movie_id, best_backdrop&.dig('file_path'), "movies/#{movie_id}/backdrop.jpg")
    enqueue_download(:movies, :logo_path, movie_id, best_logo&.dig('file_path'), "movies/#{movie_id}/logo.png")
  end
  
  def enqueue_person_headshot_download(person_id, api_path)
    enqueue_download(:people, :headshot_path, person_id, api_path, "people/#{person_id}.jpg")
  end

  def enqueue_download(table, column, id, api_path, save_path)
    return unless api_path
    
    @thread_pool.post do
      relative_path = download_image(api_path, save_path)
      if relative_path
        # FIX: Replaced .singularize with .sub to remove dependency on ActiveSupport
        id_col_name = "#{table.to_s.sub(/s\z/, '')}_id"
        @db_update_queue << { table: table, id_col: id_col_name, id_val: id, data: { column => relative_path } }
      end
    end
  end
  
  def enqueue_checksum_calculation(file_id, file_path)
    @thread_pool.post do
      checksum = MovieFileUtils.calculate_sha256(file_path)
      if checksum
        @db_update_queue << { table: :movie_files, id_col: :file_id, id_val: file_id, data: { checksum_sha256: checksum } }
      end
    end
  end

  def download_image(file_path, relative_save_path)
    return nil if file_path.nil? || file_path.empty?
    source_url = "#{TMDB_IMAGE_BASE_URL}#{file_path}"
    absolute_save_path = File.join(MEDIA_BASE_DIR, relative_save_path)
    return relative_save_path if File.exist?(absolute_save_path)
    
    FileUtils.mkdir_p(File.dirname(absolute_save_path))
    
    URI.open(source_url) do |image|
      File.open(absolute_save_path, 'wb') { |file| file.write(image.read) }
    end
    
    relative_save_path
  rescue => e
    PrettyLogger.warn "Failed to download image from #{source_url}: #{e.message}"
    nil
  end

  def populate_technical_data(conn, movie_id, video_file_path)
    mediainfo_json = run_mediainfo(video_file_path)
    return unless mediainfo_json
    
    parser = MediaInfoParser.new(mediainfo_json)
    return unless parser.valid?

    resolution_id = get_or_create_resolution(conn, parser.width, parser.height)
    video_codec_id = get_or_create_generic(conn, 'video_codecs', 'codec_name', 'codec_id', parser.video_codec)
    source_type_id = get_or_create_generic(conn, 'source_media_types', 'source_type_name', 'source_type_id', MovieFileUtils.guess_source_media_type(video_file_path))

    sql = <<~SQL
      INSERT INTO movie_files (movie_id, file_name, file_path, file_format, file_size_mb, resolution_id, video_bitrate_kbps, video_codec_id, frame_rate_fps, aspect_ratio, duration_minutes, source_media_type_id, subtitle_embedded, subtitle_external)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
      ON CONFLICT (file_path) DO NOTHING
      RETURNING file_id
    SQL
    
    result = conn.exec_params(sql, [
      movie_id, File.basename(video_file_path), File.absolute_path(video_file_path),
      parser.file_format, parser.file_size_mb, resolution_id, parser.video_bitrate_kbps,
      video_codec_id, parser.frame_rate, parser.aspect_ratio, parser.duration_minutes, source_type_id,
      !parser.subtitle_tracks.empty?, !MovieFileUtils.find_external_subtitles(video_file_path).empty?
    ])
    
    return unless result.ntuples > 0
    file_id = result.first['file_id'].to_i
    
    enqueue_checksum_calculation(file_id, video_file_path)

    # Future implementation: process audio and subtitle tracks
    # process_audio_tracks(conn, file_id, parser.audio_tracks)
    # process_subtitle_tracks(conn, file_id, parser.subtitle_tracks)
  end

  def run_mediainfo(video_file_path)
    return nil unless File.exist?(video_file_path)
    output = `mediainfo --Output=JSON -f "#{video_file_path}"`
    $?.success? ? output : nil
  end

  def get_or_create_resolution(conn, width, height)
    return nil unless width && height > 0
    res_result = conn.exec_params("SELECT resolution_id FROM video_resolutions WHERE width_pixels = $1 AND height_pixels = $2", [width, height])
    return res_result.first['resolution_id'] if res_result.ntuples > 0
    
    name = case height; when 2160.. then '4K'; when 1080 then '1080p'; when 720 then '720p'; when 480 then '480p'; else "#{height}p"; end
    conn.exec_params("INSERT INTO video_resolutions (resolution_name, width_pixels, height_pixels) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING resolution_id", [name, width, height]).first['resolution_id']
  end

  def close
    @conn&.close
    PrettyLogger.info "Database connection closed."
  end
  
  private
  
  def get_or_create_franchise(conn, collection_data)
      return nil unless collection_data && collection_data['name']
      get_or_create_generic(conn, 'franchises', 'franchise_name', 'franchise_id', collection_data['name'])
  end

  def get_or_create_generic(conn, table, name_col, id_col, name)
      return nil if name.nil? || name.to_s.strip.empty?
      find_sql = "SELECT #{id_col} FROM #{table} WHERE #{name_col} = $1"
      result = conn.exec_params(find_sql, [name])
      return result.first[id_col] if result.ntuples > 0

      insert_sql = "INSERT INTO #{table} (#{name_col}) VALUES ($1) ON CONFLICT(#{name_col}) DO UPDATE SET #{name_col}=EXCLUDED.#{name_col} RETURNING #{id_col}"
      conn.exec_params(insert_sql, [name]).first[id_col]
  end
  
  def get_or_create_languages_bulk(conn, lang_data)
    # Similar bulk logic as get_or_create_bulk but for {code, name} pairs
    return [] if lang_data.empty?
    codes = lang_data.map { |l| l[:code] }.uniq
    existing = conn.exec_params("SELECT iso_639_1_code, language_id FROM languages WHERE iso_639_1_code = ANY($1::text[])", [codes]).to_h { |r| [r['iso_639_1_code'], r['language_id']] }
    new_langs = lang_data.reject { |l| existing.key?(l[:code]) }.uniq { |l| l[:code] }
    if new_langs.any?
      new_langs.each do |lang|
        res = conn.exec_params("INSERT INTO languages (iso_639_1_code, language_name) VALUES ($1, $2) ON CONFLICT (iso_639_1_code) DO NOTHING RETURNING language_id", [lang[:code], lang[:name]])
        existing[lang[:code]] = res.first['language_id'] if res.ntuples > 0
      end
    end
    lang_data.map { |l| existing[l[:code]] }.compact
  end

  def get_or_create_countries_bulk(conn, country_data)
    # Similar bulk logic for {code, name} pairs
    return [] if country_data.empty?
    codes = country_data.map { |c| c[:code] }.uniq
    existing = conn.exec_params("SELECT iso_3166_1_code, country_id FROM production_countries WHERE iso_3166_1_code = ANY($1::text[])", [codes]).to_h { |r| [r['iso_3166_1_code'], r['country_id']] }
    new_countries = country_data.reject { |c| existing.key?(c[:code]) }.uniq { |c| c[:code] }
    if new_countries.any?
      new_countries.each do |country|
         res = conn.exec_params("INSERT INTO production_countries (iso_3166_1_code, country_name) VALUES ($1, $2) ON CONFLICT (iso_3166_1_code) DO NOTHING RETURNING country_id", [country[:code], country[:name]])
         existing[country[:code]] = res.first['country_id'] if res.ntuples > 0
      end
    end
    country_data.map { |c| existing[c[:code]] }.compact
  end
  
  def find_best_image(images, lang, type = :poster)
    return nil if images.nil? || images.empty?
    if type == :backdrop
      # For backdrops, no-language is often best.
      images.find { |i| i['iso_639_1'].nil? } || images.find { |i| i['iso_639_1'] == 'en' } || images.first
    else
      # For posters/logos, prefer specific language, then english, then no-language.
      images.find { |i| i['iso_639_1'] == lang } || images.find { |i| i['iso_639_1'] == 'en' } || images.find { |i| i['iso_639_1'].nil? } || images.first
    end
  end

  def present_search_choices(results, original_query)
    puts "\n\e[33mMultiple matches found for '#{original_query}'. Please choose:\e[0m"
    choices = results.first(8) # Show a few more choices
    choices.each_with_index do |movie, i|
      puts "  \e[32m[#{i + 1}]\e[0m #{movie['title']} (#{movie['release_date']&.slice(0,4)})"
    end
    puts "  \e[32m[0]\e[0m Skip this movie"
    
    loop do
      print "Enter your choice (0-#{choices.length}): "
      choice = STDIN.gets.to_i
      return nil if choice == 0
      return choices[choice - 1] if choice.between?(1, choices.length)
      puts "\e[31mInvalid choice. Please try again.\e[0m"
    end
  end
end

# --- MAIN EXECUTION ---
if __FILE__ == $0
  importer = nil
  begin
    movie_directory = ARGV[0]
    unless movie_directory && File.directory?(movie_directory)
      puts "Usage: #{$0} [path_to_movie_directory]"
      exit 1
    end
    
    unless system('command -v mediainfo > /dev/null 2>&1')
      PrettyLogger.error "'mediainfo' command-line tool not found. Please install it."
      exit 1
    end

    puts "\e[36m╔════════════════════════════════════════╗\e[0m"
    puts "\e[36m║     TMDB Movie Importer v3.1 (Fixed)   ║\e[0m"
    puts "\e[36m╚════════════════════════════════════════╝\e[0m"
    puts
    puts "Importing from: \e[33m#{File.absolute_path(movie_directory)}\e[0m"
    puts "Media storage:  \e[33m#{MEDIA_BASE_DIR}\e[0m"
    puts "Background Threads: \e[33m#{MAX_BG_THREADS}\e[0m"

    importer = TMDBMovieImporter.new
    importer.import_movies_from_directory(movie_directory)
    
  rescue Interrupt
    puts "\n\n[\e[33mWARN\e[0m] Import interrupted by user. Shutting down gracefully..."
    TUI.finish if TUI.active?
    # Shutdown is handled in the `ensure` block
    exit 130
  rescue => e
    PrettyLogger.error "A fatal error occurred: #{e.message}"
    PrettyLogger.error e.backtrace.join("\n") if ENV['DEBUG']
    TUI.finish if TUI.active?
    exit 1
  ensure
    # Ensure background tasks and connections are always cleaned up
    importer&.shutdown
    importer&.close
  end
end