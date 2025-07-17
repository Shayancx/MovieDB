#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# TMDB Movie Importer
#
# Description:
#   This script scans a directory for movie files, fetches metadata from The
#   Movie Database (TMDB), extracts technical details using the 'mediainfo'
#   command-line tool, and imports all the collected data into a PostgreSQL
#   database.
#
# Dependencies:
#   - Ruby gems: 'pg', 'concurrent-ruby'
#     Install with:
#       gem install pg
#       gem install concurrent-ruby
#   - Command-line tool: 'mediainfo'
#     Install via your system's package manager (e.g., `brew install mediainfo`
#     or `sudo apt-get install mediainfo`).
#
# Setup:
#   1. Create a 'database.yml' file in the same directory as this script, or
#      set the corresponding environment variables (see DatabaseService class).
#   2. Set the TMDB_API_KEY environment variable with your key from TMDB.
#      export TMDB_API_KEY="your_api_key_here"
#
# Usage:
#   ./importer.rb /path/to/your/movie/library
#
# Filename Conventions:
#   The script works best with filenames formatted in one of two ways:
#   1. With TMDB ID (fastest and most accurate):
#      "Movie Name (YYYY) (tmdbid-12345).mkv"
#   2. Standard Name and Year (requires an API search):
#      "Movie Name (YYYY).mkv"
# ==============================================================================

# --- Standard Library Requirements ---
require 'pg'
require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'fileutils'
require 'set'
require 'open-uri'
require 'digest'
require 'thread'

# --- Gem Requirements ---
require 'concurrent'

# ==============================================================================
# --- CONFIGURATION ---
# ==============================================================================
# The base URL for the TMDB API.
TMDB_API_BASE_URL = 'https://api.themoviedb.org/3'
# The base URL for fetching TMDB images.
TMDB_IMAGE_BASE_URL = 'https://image.tmdb.org/t/p/original'
# The root directory where media assets (posters, backdrops) will be stored.
MEDIA_BASE_DIR = File.join(Dir.pwd, 'media')
# The maximum number of concurrent threads for background tasks like downloads.
# Can be overridden by the MAX_BG_THREADS environment variable.
MAX_BG_THREADS = ENV.fetch('MAX_BG_THREADS', 5).to_i
# The API key for TMDB. It is mandatory and must be set as an environment variable.
TMDB_API_KEY = ENV.fetch('TMDB_API_KEY') do
  # This block runs if the environment variable is not set.
  puts "\n[\e[31mFATAL\e[0m] TMDB_API_KEY environment variable not set."
  puts "Please set it before running the script:"
  puts "  export TMDB_API_KEY=\"your_key_here\""
  exit 1
end

# ==============================================================================
# --- UTILITY CLASSES ---
# ==============================================================================

# --- PrettyLogger ---
# A simple, colorized logger for providing user feedback.
# It accumulates warnings and errors to display them in a final summary.
class PrettyLogger
  # Using thread-safe arrays for accumulating messages in a concurrent environment.
  @@errors = Concurrent::Array.new
  @@warnings = Concurrent::Array.new

  def self.info(msg); puts "[\e[34mINFO\e[0m] #{msg}"; end
  def self.success(msg); puts "[\e[32mSUCCESS\e[0m] #{msg}"; end
  def self.debug(msg); puts "[\e[35mDEBUG\e[0m] #{msg}" if ENV['DEBUG']; end

  # For warnings and errors, we store them to show at the end, unless the TUI is inactive.
  def self.warn(msg)
    @@warnings << msg
    puts "\n[\e[33mWARN\e[0m] #{msg}" unless TUI.active?
  end

  def self.error(msg)
    @@errors << msg
    puts "\n[\e[31mERROR\e[0m] #{msg}" unless TUI.active?
  end

  # Displays a final summary of all accumulated warnings and errors.
  def self.display_summary
    puts "\n--- Import Summary ---"
    if @@warnings.empty? && @@errors.empty?
      success("Completed with 0 errors and 0 warnings.")
    else
      if @@warnings.any?
        puts "\n[\e[33mWarnings (#{@@warnings.length}):\e[0m]"
        @@warnings.each { |w| puts "  • #{w}" }
      end
      if @@errors.any?
        puts "\n[\e[31mErrors (#{@@errors.length}):\e[0m]"
        @@errors.each { |e| puts "  • #{e}" }
      end
    end
    @@warnings.clear
    @@errors.clear
  end
end

# --- TUI (Terminal User Interface) ---
# Manages the progress bar and status updates in the terminal.
class TUI
  @@active = false

  def self.active?; @@active; end

  def self.start(total)
    return if total.zero?
    @@active = true
    @total = total
    @count = 0
    @start_time = Time.now
    puts "\n" # Add space for the TUI
    update_progress
    update_status("Initializing...")
  end

  def self.increment(name)
    return unless @@active
    @count += 1
    update_progress
    update_status(name)
  end

  def self.finish
    return unless @@active && @start_time
    @count = @total if @count < @total # Ensure bar is 100% on finish
    update_progress
    elapsed = Time.now - @start_time
    update_status("Import finished in #{format_duration(elapsed)}.")
    puts "\n" # Move cursor to a new line after the TUI
    @@active = false
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
      remaining_time = (@total - @count) * (elapsed / @count)
      " - ETA: #{format_duration(remaining_time)}"
    else
      ""
    end
    
    # ANSI escape codes: move cursor up 2 lines, clear to end of line
    print "\e[2A\e[K"
    puts "  \e[36mProcessing\e[0m [#{bar}] #{@count}/#{@total} (#{(percent * 100).to_i}%)#{eta}"
  end

  def self.update_status(name)
    # ANSI escape code: clear to end of line
    print "\e[K"
    puts "  \e[2m└─ Currently:\e[0m #{name}"
  end
end

# ==============================================================================
# --- SERVICE CLASSES ---
# ==============================================================================

# --- TmdbClient ---
# Responsible for all communication with the TMDB API.
class TmdbClient
  def initialize
    uri = URI(TMDB_API_BASE_URL)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    @http.open_timeout = 10 # seconds
    @http.read_timeout = 30 # seconds
  end

  # Searches for a movie by its name and year.
  def search_movie(name, year)
    response = make_api_request('/search/movie', { query: name, year: year }.compact)
    (response && response['results']) || []
  end

  # Fetches detailed information for a specific movie by its TMDB ID.
  def get_movie_details(tmdb_id)
    # 'append_to_response' is a powerful TMDB feature to get multiple data types
    # in a single API call, reducing network latency.
    make_api_request("/movie/#{tmdb_id}", append_to_response: 'credits,release_dates,images')
  end

  # Downloads an image from TMDB to a specified local path.
  def download_image(api_path, relative_save_path)
    return nil if api_path.nil? || api_path.empty?
    source_url = "#{TMDB_IMAGE_BASE_URL}#{api_path}"
    absolute_save_path = File.join(MEDIA_BASE_DIR, relative_save_path)
    
    # If the file already exists, don't re-download it.
    return relative_save_path if File.exist?(absolute_save_path)
    
    # Ensure the target directory exists before writing the file.
    FileUtils.mkdir_p(File.dirname(absolute_save_path))
    
    # Using open-uri to handle the download. Includes retry logic.
    retry_with_backoff do
      URI.open(source_url) do |image|
        File.open(absolute_save_path, 'wb') { |file| file.write(image.read) }
      end
    end
    
    PrettyLogger.debug("Downloaded image to #{relative_save_path}")
    relative_save_path
  rescue => e
    PrettyLogger.warn("Failed to download image from #{source_url}: #{e.message}")
    nil
  end

  private

  # A robust, generic method for making API requests with error handling and retries.
  def make_api_request(path, params = {}, retries = 3)
    params[:api_key] = TMDB_API_KEY
    uri = URI("#{TMDB_API_BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)
    
    request = Net::HTTP::Get.new(uri)
    response = @http.request(request)
    
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    when Net::HTTPTooManyRequests # API Rate Limiting
      retry_after = response['Retry-After']&.to_i || 10
      PrettyLogger.warn("Rate limited by TMDB API. Waiting #{retry_after} seconds...")
      sleep(retry_after)
      make_api_request(path, params) # Retry the request
    else
      # For other errors (e.g., 404 Not Found, 500 Server Error), log and return nil.
      PrettyLogger.warn("API request failed for '#{path}': #{response.code} #{response.message}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
    # Handle common network errors with a retry mechanism.
    if retries > 0
      PrettyLogger.warn("Network error (#{e.class}). Retrying in #{5 - retries}s...")
      sleep(5 - retries)
      make_api_request(path, params, retries - 1)
    else
      PrettyLogger.error("API request failed after multiple retries for '#{path}': #{e.message}")
      nil
    end
  end

  # A helper to retry a block of code with exponential backoff.
  def retry_with_backoff(times = 3)
    yield
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, OpenURI::HTTPError => e
    if (times -= 1) > 0
      sleep(3 - times) # Sleep for 1, 2, 3 seconds
      retry
    else
      raise e # Re-raise the exception if all retries fail
    end
  end
end

# --- DatabaseService ---
# Manages all database connections and query executions.
class DatabaseService
  attr_reader :conn

  def initialize(config_file = 'database.yml')
    @db_config = load_db_config(config_file)
    @conn = connect_to_db
  end

  # Fetches all existing movie file paths from the DB to avoid re-importing.
  def get_existing_file_paths
    @conn.exec("SELECT file_path FROM movie_files").map { |row| row['file_path'] }.to_set
  end

  # Inserts or updates a movie's core data.
  def insert_movie(details)
    franchise_id = get_or_create_franchise(details['belongs_to_collection'])
    
    sql = <<~SQL
      INSERT INTO movies (movie_name, original_title, release_date, description, runtime_minutes, imdb_id, tmdb_id, rating, franchise_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      ON CONFLICT (tmdb_id) DO UPDATE SET
        movie_name = EXCLUDED.movie_name,
        original_title = EXCLUDED.original_title,
        release_date = EXCLUDED.release_date,
        description = EXCLUDED.description,
        runtime_minutes = EXCLUDED.runtime_minutes,
        imdb_id = EXCLUDED.imdb_id,
        rating = EXCLUDED.rating
      RETURNING movie_id
    SQL
    
    result = @conn.exec_params(sql, [
      details['title'], details['original_title'], details['release_date'],
      details['overview'], details['runtime'], details['imdb_id'], details['id'],
      details['vote_average']&.round(1), franchise_id
    ])
    result.first['movie_id'].to_i
  end
  
  # Inserts the technical data for a movie file.
  def insert_movie_file(movie_id, file_path, mediainfo)
    resolution_id = get_or_create_resolution(mediainfo.width, mediainfo.height)
    video_codec_id = get_or_create_generic('video_codecs', 'codec_name', 'codec_id', mediainfo.video_codec)
    source_type_id = get_or_create_generic('source_media_types', 'source_type_name', 'source_type_id', guess_source_media_type(file_path))

    sql = <<~SQL
      INSERT INTO movie_files (movie_id, file_name, file_path, file_format, file_size_mb, resolution_id, video_bitrate_kbps, video_codec_id, frame_rate_fps, aspect_ratio, duration_minutes, source_media_type_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
      ON CONFLICT (file_path) DO NOTHING
      RETURNING file_id
    SQL
    
    result = @conn.exec_params(sql, [
      movie_id, File.basename(file_path), File.absolute_path(file_path),
      mediainfo.file_format, mediainfo.file_size_mb, resolution_id, mediainfo.video_bitrate_kbps,
      video_codec_id, mediainfo.frame_rate, mediainfo.aspect_ratio, mediainfo.duration_minutes, source_type_id
    ])
    
    result.ntuples > 0 ? result.first['file_id'].to_i : nil
  end

  # A central method to handle all associations for a movie in a single transaction.
  def bulk_import_associations(movie_id, details)
    # People (Cast & Crew)
    cast_data = (details.dig('credits', 'cast') || []).first(50)
    crew_data = (details.dig('credits', 'crew') || [])
    people_data = (cast_data + crew_data).uniq { |p| p['id'] }
    people_map = get_or_create_people_bulk(people_data)
    link_cast_bulk(movie_id, cast_data, people_map)
    link_crew_bulk(movie_id, crew_data, people_map)

    # Genres
    genre_names = (details['genres'] || []).map { |g| g['name'] }
    genre_ids = get_or_create_generic_bulk('genres', 'genre_name', 'genre_id', genre_names)
    link_generic_bulk('movie_genres', 'movie_id', 'genre_id', movie_id, genre_ids)

    # Production Countries
    country_data = (details['production_countries'] || []).map { |c| [c['iso_3166_1'], c['name']] }
    country_ids = get_or_create_code_name_bulk('production_countries', 'iso_3166_1_code', 'country_name', 'country_id', country_data)
    link_generic_bulk('movie_countries', 'movie_id', 'country_id', movie_id, country_ids)

    # Spoken Languages
    lang_data = (details['spoken_languages'] || []).map { |l| [l['iso_639_1'], l['english_name']] }
    lang_ids = get_or_create_code_name_bulk('languages', 'iso_639_1_code', 'language_name', 'language_id', lang_data)
    link_generic_bulk('movie_languages', 'movie_id', 'language_id', movie_id, lang_ids)
  end
  
  # Asynchronously updates a single column for a given record. Used by background jobs.
  def update_record(table:, id_col:, id_val:, data:)
    # This method is designed to be called from multiple threads, so it needs to be robust.
    # It constructs and executes a simple UPDATE statement.
    sql = "UPDATE #{table} SET "
    sql += data.keys.map.with_index { |k, i| "#{k} = $#{i + 1}" }.join(', ')
    sql += " WHERE #{id_col} = $#{data.size + 1}"
    
    values = data.values + [id_val]
    
    @conn.exec_params(sql, values)
    PrettyLogger.debug("DB updated for #{table}##{id_val}")
  rescue PG::Error => e
    PrettyLogger.error("DB update failed for #{table}##{id_val}: #{e.message}")
  end

  def close; @conn&.close; end

  private
  
  # Loads database configuration from a YAML file or environment variables.
  def load_db_config(config_file)
    YAML.load_file(config_file)
  rescue Errno::ENOENT
    PrettyLogger.warn("Database config '#{config_file}' not found. Using ENV variables or defaults.")
    {
      'host' => ENV['DB_HOST'] || 'localhost', 'port' => ENV['DB_PORT'] || 5432,
      'dbname' => ENV['DB_NAME'] || 'MovieDB', 'user' => ENV['DB_USER'] || ENV['USER'] || 'postgres',
      'password' => ENV['DB_PASSWORD'] || ''
    }
  end

  def connect_to_db
    PG.connect(@db_config)
  rescue PG::Error => e
    PrettyLogger.error("Failed to connect to PostgreSQL database: #{e.message}")
    raise # Terminate the script if DB connection fails.
  end
  
  # --- Bulk Data Handling Methods ---
  # These methods are optimized for inserting many records at once, which is
  # much faster than inserting one record at a time.

  # Efficiently finds or creates multiple records that have a single unique name column.
  def get_or_create_generic_bulk(table, name_col, id_col, names)
    return [] if names.empty?
    
    # Use PostgreSQL's `unnest` to insert all new names in a single query.
    sql = <<~SQL
      WITH new_names (name) AS (
        SELECT * FROM unnest($1::text[])
      ),
      ins AS (
        INSERT INTO #{table} (#{name_col})
        SELECT name FROM new_names
        ON CONFLICT (#{name_col}) DO NOTHING
        RETURNING #{id_col}, #{name_col}
      )
      SELECT #{id_col}, #{name_col} FROM ins
      UNION ALL
      SELECT t.#{id_col}, t.#{name_col} FROM #{table} t JOIN new_names nn ON t.#{name_col} = nn.name
    SQL
    
    result = @conn.exec_params(sql, [names.uniq])
    result.to_h { |row| [row[name_col], row[id_col]] }
          .values_at(*names).compact
  end

  # Efficiently finds or creates records with a code and a name (e.g., countries, languages).
  def get_or_create_code_name_bulk(table, code_col, name_col, id_col, data)
    return [] if data.empty?
    
    codes = data.map(&:first).uniq
    
    sql = <<~SQL
      WITH new_data (code, name) AS (
        SELECT * FROM unnest($1::text[], $2::text[])
      ),
      ins AS (
        INSERT INTO #{table} (#{code_col}, #{name_col})
        SELECT code, name FROM new_data
        ON CONFLICT (#{code_col}) DO NOTHING
        RETURNING #{id_col}, #{code_col}
      )
      SELECT #{id_col}, #{code_col} FROM ins
      UNION ALL
      SELECT t.#{id_col}, t.#{code_col} FROM #{table} t JOIN new_data nd ON t.#{code_col} = nd.code
    SQL
    
    result = @conn.exec_params(sql, [data.map(&:first), data.map(&:last)])
    id_map = result.to_h { |row| [row[code_col], row[id_col]] }
    codes.map { |code| id_map[code] }.compact
  end

  # Efficiently finds or creates multiple people records.
  def get_or_create_people_bulk(people_data)
    return {} if people_data.empty?
    tmdb_ids = people_data.map { |p| p['id'] }.uniq
    
    # Prepare data for insertion
    people_values = people_data.map do |p|
      name_parts = p['name'].split(/\s+/, 2)
      [p['id'], p['name'], name_parts[0], name_parts[1]]
    end.uniq { |p| p[0] } # Unique by TMDB ID

    # This single query finds existing people and inserts new ones, returning all IDs.
    sql = <<~SQL
      WITH new_people (tmdb_id, full_name, first_name, last_name) AS (
        SELECT * FROM unnest($1::int[], $2::text[], $3::text[], $4::text[])
      ),
      ins AS (
        INSERT INTO people (tmdb_person_id, full_name, first_name, last_name)
        SELECT tmdb_id, full_name, first_name, last_name FROM new_people
        ON CONFLICT (tmdb_person_id) DO NOTHING
        RETURNING person_id, tmdb_person_id
      )
      SELECT person_id, tmdb_person_id FROM ins
      UNION ALL
      SELECT p.person_id, p.tmdb_person_id FROM people p JOIN new_people np ON p.tmdb_person_id = np.tmdb_id
    SQL

    result = @conn.exec_params(sql, [
      people_values.map { |p| p[0] }, # tmdb_ids
      people_values.map { |p| p[1] }, # full_names
      people_values.map { |p| p[2] }, # first_names
      people_values.map { |p| p[3] }  # last_names
    ])
    
    # Create a map of { tmdb_person_id => internal_person_id }
    result.to_h { |row| [row['tmdb_person_id'].to_i, row['person_id'].to_i] }
  end

  # Uses the super-fast `COPY` command to insert many-to-many links.
  def link_generic_bulk(link_table, movie_id_col, other_id_col, movie_id, other_ids)
    return if other_ids.empty?
    @conn.copy_data "COPY #{link_table} (#{movie_id_col}, #{other_id_col}) FROM STDIN" do
      other_ids.uniq.each do |other_id|
        @conn.put_copy_data "#{movie_id}\t#{other_id}\n"
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Links for #{link_table} and movie ##{movie_id} may already exist.")
  end

  # Links cast members to a movie, including character name and billing order.
  def link_cast_bulk(movie_id, cast_data, people_map)
    return if cast_data.empty?
    @conn.copy_data "COPY movie_cast (movie_id, person_id, character_name, billing_order) FROM STDIN" do
      cast_data.each do |member|
        person_id = people_map[member['id']]
        next unless person_id && member['character']
        # Data must be tab-separated for COPY
        row = [movie_id, person_id, member['character'], member['order'] + 1].join("\t")
        @conn.put_copy_data "#{row}\n"
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Cast for movie ##{movie_id} already linked.")
  end
  
  # Links crew members (directors, writers) to a movie.
  def link_crew_bulk(movie_id, crew_data, people_map)
    directors = crew_data.select { |c| c['job'] == 'Director' }
    writers = crew_data.select { |c| ['Screenplay', 'Writer', 'Story'].include?(c['job']) }
    
    director_ids = directors.map { |d| people_map[d['id']] }.compact
    writer_ids = writers.map { |w| people_map[w['id']] }.compact
    
    link_generic_bulk('movie_directors', 'movie_id', 'person_id', movie_id, director_ids)
    link_generic_bulk('movie_writers', 'movie_id', 'person_id', movie_id, writer_ids)
  end
  
  # --- Single Record Get-or-Create Methods ---
  # Used for entities that are not typically bulk inserted in this script.

  def get_or_create_franchise(collection_data)
    return nil unless collection_data && collection_data['name']
    get_or_create_generic('franchises', 'franchise_name', 'franchise_id', collection_data['name'])
  end

  def get_or_create_resolution(width, height)
    return nil unless width && height > 0
    sql = "SELECT resolution_id FROM video_resolutions WHERE width_pixels = $1 AND height_pixels = $2"
    res = @conn.exec_params(sql, [width, height])
    return res.first['resolution_id'] if res.ntuples > 0
    
    name = case height
           when 2160..; '4K'
           when 1080; '1080p'
           when 720; '720p'
           when 480; '480p'
           else "#{height}p"
           end
    insert_sql = "INSERT INTO video_resolutions (resolution_name, width_pixels, height_pixels) VALUES ($1, $2, $3) RETURNING resolution_id"
    @conn.exec_params(insert_sql, [name, width, height]).first['resolution_id']
  end

  def get_or_create_generic(table, name_col, id_col, name)
    return nil if name.nil? || name.to_s.strip.empty?
    find_sql = "SELECT #{id_col} FROM #{table} WHERE #{name_col} = $1"
    result = @conn.exec_params(find_sql, [name])
    return result.first[id_col] if result.ntuples > 0

    insert_sql = "INSERT INTO #{table} (#{name_col}) VALUES ($1) ON CONFLICT(#{name_col}) DO UPDATE SET #{name_col}=EXCLUDED.#{name_col} RETURNING #{id_col}"
    @conn.exec_params(insert_sql, [name]).first[id_col]
  end
  
  def guess_source_media_type(file_path)
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

# --- MediaInfoParser ---
# Executes the 'mediainfo' CLI tool and parses its JSON output.
class MediaInfoParser
  attr_reader :width, :height, :file_format, :duration_minutes, :file_size_mb,
              :video_codec, :video_bitrate_kbps, :frame_rate, :aspect_ratio

  def initialize(file_path)
    json_output = `mediainfo --Output=JSON -f "#{file_path}"`
    @data = $?.success? ? JSON.parse(json_output) : nil
    @media = @data ? @data['media'] : nil
    parse
  end

  def valid?; !@media.nil?; end

  private

  def parse
    return unless valid?
    general = track('General')
    video = track('Video')
    
    return unless general && video

    @file_format = general['Format']
    @duration_minutes = (general['Duration'].to_f / 60).round
    @file_size_mb = (general['FileSize'].to_f / 1024 / 1024).round
    @video_codec = video['Format']
    @video_bitrate_kbps = (video['BitRate'].to_f / 1000).round
    @frame_rate = video['FrameRate'].to_f.round(3)
    @aspect_ratio = normalize_aspect_ratio(video['DisplayAspectRatio'])
    @width = video['Width'].to_i
    @height = video['Height'].to_i
  end
  
  def track(type); (@media['track'] || []).find { |t| t['@type'] == type }; end
  
  def normalize_aspect_ratio(ratio_str)
    # A map to standardize common aspect ratio representations.
    {
      '1.33:1' => '1.33', '4:3' => '1.33', '1.37:1' => '1.33', '1.66:1' => '1.66',
      '1.78:1' => '1.78', '16:9' => '1.78', '1.85:1' => '1.85', '2.00:1' => '2.00',
      '2.20:1' => '2.20', '2.35:1' => '2.35', '2.39:1' => '2.39', '2.40:1' => '2.39'
    }[ratio_str]
  end
end

# ==============================================================================
# --- MAIN ORCHESTRATOR CLASS ---
# ==============================================================================

class TMDBMovieImporter
  def initialize
    # The importer now delegates tasks to specialized service objects.
    @db_service = DatabaseService.new
    @tmdb_client = TmdbClient.new
    
    # The thread pool for running background jobs (downloads, checksums).
    @thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: MAX_BG_THREADS,
      max_queue: MAX_BG_THREADS * 2,
      fallback_policy: :caller_runs # If queue is full, the main thread runs the task.
    )
    
    # A queue to hold database update jobs from background threads.
    @db_update_queue = Queue.new
    # A dedicated thread to process database updates sequentially.
    @db_updater_thread = Thread.new { process_db_updates }
    
    setup_media_directories
  end

  # The main entry point for the import process.
  def import_from_directory(directory)
    PrettyLogger.info "Fetching existing movie library from database..."
    existing_paths = @db_service.get_existing_file_paths

    PrettyLogger.info "Scanning '#{directory}' for new movie files..."
    video_extensions = '{mkv,mp4,mov,avi,m2ts}'
    all_files = Dir.glob(File.join(directory, "**", "*.#{video_extensions}"), File::FNM_CASEFOLD).sort
    movies_to_process = all_files.reject { |file| existing_paths.include?(File.absolute_path(file)) }

    display_scan_summary(all_files.length, movies_to_process.length)
    return if movies_to_process.empty?
    
    TUI.start(movies_to_process.length)
    
    movies_to_process.each do |file_path|
      process_movie_file(file_path)
      # A small delay helps avoid hitting API rate limits during rapid-fire searches.
      sleep(0.1) 
    end
    
    TUI.finish
  end

  # Gracefully shuts down the thread pool and database connections.
  def shutdown
    return if @shutdown_started
    @shutdown_started = true
    
    PrettyLogger.info "Waiting for background tasks to complete..."
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(600) # Wait up to 10 minutes
    
    # Signal the DB updater thread to finish, then wait for it.
    @db_update_queue.close
    @db_updater_thread.join if @db_updater_thread.alive?
    
    @db_service.close
    PrettyLogger.success "All background tasks finished and connections closed."
  end

  private

  # Processes a single movie file from its path.
  def process_movie_file(file_path)
    filename = File.basename(file_path)
    TUI.increment(filename)
    
    # 1. Parse filename to get movie title, year, and optionally TMDB ID.
    parsed_info = parse_filename(filename)
    unless parsed_info
      PrettyLogger.error("Could not parse movie info from filename: #{filename}")
      return
    end

    # 2. Get movie details from TMDB.
    details = fetch_movie_details(parsed_info)
    unless details
      PrettyLogger.error("Could not find TMDB details for: #{parsed_info[:name]} (#{parsed_info[:year]})")
      return
    end

    # 3. Process all data within a single database transaction for integrity.
    @db_service.conn.transaction do
      # 3a. Insert core movie data.
      movie_id = @db_service.insert_movie(details)
      
      # 3b. Insert all related data (genres, actors, etc.).
      @db_service.bulk_import_associations(movie_id, details)
      
      # 3c. Insert technical file data.
      process_technical_data(movie_id, file_path)
      
      # 3d. Enqueue background jobs for image downloads.
      enqueue_image_downloads(movie_id, details)
    end
    
  rescue => e
    PrettyLogger.error("Fatal error processing '#{filename}': #{e.message}")
    PrettyLogger.debug(e.backtrace.join("\n"))
  end
  
  # Parses the movie filename to extract metadata.
  def parse_filename(filename)
    base = File.basename(filename, '.*')
    if match = base.match(/^(.+?)\s\((\d{4})\)\s\(tmdbid-(\d+)\)$/i)
      { name: match[1].strip, year: match[2].to_i, tmdb_id: match[3].to_i }
    elsif match = base.match(/^(.+?)\s*\((\d{4})\)/)
      { name: match[1].gsub('.', ' ').strip, year: match[2].to_i }
    else
      nil
    end
  end

  # Fetches movie details either by ID or by searching.
  def fetch_movie_details(parsed_info)
    if parsed_info[:tmdb_id]
      @tmdb_client.get_movie_details(parsed_info[:tmdb_id])
    else
      results = @tmdb_client.search_movie(parsed_info[:name], parsed_info[:year])
      return nil if results.empty?
      
      # If multiple results, ask the user to choose.
      chosen_movie = results.length == 1 ? results.first : present_search_choices(results, parsed_info[:name])
      return nil unless chosen_movie
      
      # Fetch full details for the chosen movie.
      @tmdb_client.get_movie_details(chosen_movie['id'])
    end
  end
  
  # Handles mediainfo parsing and database insertion for technical data.
  def process_technical_data(movie_id, file_path)
    mediainfo = MediaInfoParser.new(file_path)
    unless mediainfo.valid?
      PrettyLogger.warn("Could not read mediainfo for: #{File.basename(file_path)}")
      return
    end
    
    file_id = @db_service.insert_movie_file(movie_id, file_path, mediainfo)
    
    # Enqueue a background job to calculate the file's checksum.
    enqueue_checksum_calculation(file_id, file_path) if file_id
  end

  # Adds image download jobs to the thread pool.
  def enqueue_image_downloads(movie_id, details)
    images = details['images']
    return unless images

    # Find the best images based on language preference.
    poster = find_best_image(images['posters'], details['original_language'])
    backdrop = find_best_image(images['backdrops'], details['original_language'], :backdrop)
    logo = find_best_image(images['logos'], details['original_language'])
    
    # People headshots
    people_with_headshots = (details.dig('credits', 'cast') || []).select { |p| p['profile_path'] }
    
    # Enqueue each download as a separate job.
    enqueue_download(:movies, :poster_path, movie_id, poster&.dig('file_path'), "movies/#{movie_id}/poster.jpg")
    enqueue_download(:movies, :backdrop_path, movie_id, backdrop&.dig('file_path'), "movies/#{movie_id}/backdrop.jpg")
    enqueue_download(:movies, :logo_path, movie_id, logo&.dig('file_path'), "movies/#{movie_id}/logo.png")
  end

  # Generic method to add a download job to the thread pool.
  def enqueue_download(table, column, id, api_path, save_path)
    return unless api_path
    
    @thread_pool.post do
      relative_path = @tmdb_client.download_image(api_path, save_path)
      if relative_path
        # When the download is complete, add an update job to the DB queue.
        id_col_name = "#{table.to_s.chomp('s')}_id"
        @db_update_queue << { table: table, id_col: id_col_name, id_val: id, data: { column => File.basename(relative_path) } }
      end
    end
  end
  
  # Adds a checksum calculation job to the thread pool.
  def enqueue_checksum_calculation(file_id, file_path)
    @thread_pool.post do
      digest = Digest::SHA256.new
      File.open(file_path, 'rb') do |file|
        while chunk = file.read(1024 * 1024) # Read in 1MB chunks
          digest.update(chunk)
        end
      end
      checksum = digest.hexdigest
      @db_update_queue << { table: :movie_files, id_col: :file_id, id_val: file_id, data: { checksum_sha256: checksum } }
    rescue => e
      PrettyLogger.warn("Failed to calculate checksum for #{File.basename(file_path)}: #{e.message}")
    end
  end

  # The loop for the dedicated database updater thread.
  def process_db_updates
    # This loop will block and wait for a job to appear in the queue.
    # It will exit when the queue is closed and empty.
    while (update_job = @db_update_queue.pop)
      begin
        @db_service.update_record(**update_job)
      rescue => e
        PrettyLogger.error("Unexpected error in DB updater thread: #{e.message}")
      end
    end
  end
  
  # --- Helper Methods ---

  def setup_media_directories
    %w[movies people].each { |subdir| FileUtils.mkdir_p(File.join(MEDIA_BASE_DIR, subdir)) }
  end

  def display_scan_summary(total, to_process)
    puts "---------------------------"
    PrettyLogger.info "Scan Complete: Found #{total} movie files."
    PrettyLogger.success "  - #{total - to_process} movies are already in the database."
    PrettyLogger.info "  - #{to_process} new movies will be imported."
    puts "---------------------------"
  end
  
  def find_best_image(images, lang, type = :poster)
    return nil if images.nil? || images.empty?
    # Prioritize images in the movie's original language, then English, then language-neutral.
    images.find { |i| i['iso_639_1'] == lang } ||
    images.find { |i| i['iso_639_1'] == 'en' } ||
    images.find { |i| i['iso_639_1'].nil? } ||
    images.first
  end

  def present_search_choices(results, query)
    puts "\n\e[33mMultiple matches found for '#{query}'. Please choose:\e[0m"
    choices = results.first(8)
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


# ==============================================================================
# --- SCRIPT EXECUTION ---
# ==============================================================================
if __FILE__ == $0
  # This block only runs when the script is executed directly.
  importer = nil
  
  # --- Pre-run Checks ---
  unless system('command -v mediainfo > /dev/null 2>&1')
    PrettyLogger.error("'mediainfo' command-line tool not found. Please install it first.")
    exit 1
  end

  movie_directory = ARGV[0]
  unless movie_directory && File.directory?(movie_directory)
    puts "Usage: #{$0} [path_to_movie_directory]"
    exit 1
  end

  # --- Main Execution Block ---
  begin
    puts "\e[36m╔════════════════════════════════════════╗\e[0m"
    puts "\e[36m║    TMDB Movie Importer (Revised)     ║\e[0m"
    puts "\e[36m╚════════════════════════════════════════╝\e[0m"
    puts
    puts "Importing from:   \e[33m#{File.absolute_path(movie_directory)}\e[0m"
    puts "Media storage:    \e[33m#{MEDIA_BASE_DIR}\e[0m"
    puts "Background Threads: \e[33m#{MAX_BG_THREADS}\e[0m"

    importer = TMDBMovieImporter.new
    importer.import_from_directory(movie_directory)
    
  rescue Interrupt
    # Handle Ctrl+C gracefully.
    puts "\n\n[\e[33mWARN\e[0m] Import interrupted by user. Shutting down gracefully..."
    TUI.finish if TUI.active?
    # The `ensure` block will handle the actual shutdown.
    exit 130
  rescue => e
    # Catch any other unexpected fatal errors.
    PrettyLogger.error("A fatal error occurred: #{e.message}")
    PrettyLogger.debug(e.backtrace.join("\n"))
    TUI.finish if TUI.active?
    exit 1
  ensure
    # This block *always* runs, whether the script finishes, is interrupted, or errors out.
    # It's the perfect place to ensure cleanup happens.
    importer&.shutdown
    PrettyLogger.display_summary
  end
end

