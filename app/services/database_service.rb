require 'pg'
require 'yaml'
require 'set'
require_relative 'pretty_logger'

class DatabaseService
  attr_reader :conn

  def initialize(config_file = nil)
    config_file ||= File.expand_path('../../config/database.yml', __dir__)
    @db_config = load_db_config(config_file)
    @conn = connect_to_db
  end

  def get_existing_file_paths
    @conn.exec('SELECT file_path FROM movie_files').map { |row| row['file_path'] }.to_set
  end

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

  def bulk_import_associations(movie_id, details)
    cast_data = (details.dig('credits', 'cast') || []).first(50)
    crew_data = (details.dig('credits', 'crew') || [])
    people_data = (cast_data + crew_data).uniq { |p| p['id'] }
    people_map = get_or_create_people_bulk(people_data)
    link_cast_bulk(movie_id, cast_data, people_map)
    link_crew_bulk(movie_id, crew_data, people_map)

    genre_names = (details['genres'] || []).map { |g| g['name'] }
    genre_ids = get_or_create_generic_bulk('genres', 'genre_name', 'genre_id', genre_names)
    link_generic_bulk('movie_genres', 'movie_id', 'genre_id', movie_id, genre_ids)

    country_data = (details['production_countries'] || []).map { |c| [c['iso_3166_1'], c['name']] }
    country_ids = get_or_create_code_name_bulk('production_countries', 'iso_3166_1_code', 'country_name', 'country_id', country_data)
    link_generic_bulk('movie_countries', 'movie_id', 'country_id', movie_id, country_ids)

    lang_data = (details['spoken_languages'] || []).map { |l| [l['iso_639_1'], l['english_name']] }
    lang_ids = get_or_create_code_name_bulk('languages', 'iso_639_1_code', 'language_name', 'language_id', lang_data)
    link_generic_bulk('movie_languages', 'movie_id', 'language_id', movie_id, lang_ids)
  end

  def update_record(table:, id_col:, id_val:, data:)
    sql = "UPDATE #{table} SET "
    sql += data.keys.map.with_index { |k, i| "#{k} = $#{i + 1}" }.join(', ')
    sql += " WHERE #{id_col} = $#{data.size + 1}"
    values = data.values + [id_val]
    @conn.exec_params(sql, values)
    PrettyLogger.debug("DB updated for #{table}##{id_val}")
  rescue PG::Error => e
    PrettyLogger.error("DB update failed for #{table}##{id_val}: #{e.message}")
  end

  def close
    @conn&.close
  end

  private

  def load_db_config(config_file)
    YAML.load_file(config_file)
  rescue Errno::ENOENT
    PrettyLogger.warn("Database config '#{config_file}' not found. Using ENV variables or defaults.")
    {
      'host' => ENV['DB_HOST'] || 'localhost',
      'port' => ENV['DB_PORT'] || 5432,
      'dbname' => ENV['DB_NAME'] || 'MovieDB',
      'user' => ENV['DB_USER'] || ENV['USER'] || 'postgres',
      'password' => ENV['DB_PASSWORD'] || ''
    }
  end

  def connect_to_db
    PG.connect(@db_config)
  rescue PG::Error => e
    PrettyLogger.error("Failed to connect to PostgreSQL database: #{e.message}")
    raise
  end

  def get_or_create_generic_bulk(table, name_col, id_col, names)
    return [] if names.empty?
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
      SELECT #{id_col}, #{name_col} FROM #{table} WHERE #{name_col} = ANY($1)
    SQL
    res = @conn.exec_params(sql, [names])
    res.map { |r| r[id_col] }
  end

  def get_or_create_code_name_bulk(table, code_col, name_col, id_col, data)
    return [] if data.empty?
    codes = data.map(&:first)
    sql = <<~SQL
      WITH new_items (code, name) AS (
        SELECT * FROM unnest($1::text[], $2::text[])
      ),
      ins AS (
        INSERT INTO #{table} (#{code_col}, #{name_col})
        SELECT code, name FROM new_items
        ON CONFLICT (#{code_col}) DO NOTHING
        RETURNING #{id_col}, #{code_col}
      )
      SELECT #{id_col}, #{code_col} FROM ins
      UNION ALL
      SELECT #{id_col}, #{code_col} FROM #{table} WHERE #{code_col} = ANY($1)
    SQL
    res = @conn.exec_params(sql, [codes, data.map(&:last)])
    res.map { |r| r[id_col] }
  end

  def get_or_create_people_bulk(people)
    return {} if people.empty?
    tmdb_ids = people.map { |p| p['id'] }
    sql = <<~SQL
      WITH new_people (tmdb_id, full_name) AS (
        SELECT * FROM unnest($1::int[], $2::text[])
      ),
      ins AS (
        INSERT INTO people (tmdb_id, full_name)
        SELECT tmdb_id, full_name FROM new_people
        ON CONFLICT (tmdb_id) DO NOTHING
        RETURNING person_id, tmdb_id
      )
      SELECT person_id, tmdb_id FROM ins
      UNION ALL
      SELECT person_id, tmdb_id FROM people WHERE tmdb_id = ANY($1)
    SQL
    res = @conn.exec_params(sql, [tmdb_ids, people.map { |p| p['name'] }])
    res.each_with_object({}) { |r, h| h[r['tmdb_id'].to_i] = r['person_id'].to_i }
  end

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

  def link_cast_bulk(movie_id, cast_data, people_map)
    return if cast_data.empty?
    @conn.copy_data "COPY movie_cast (movie_id, person_id, character_name, billing_order) FROM STDIN" do
      cast_data.each do |member|
        person_id = people_map[member['id']]
        next unless person_id && member['character']
        row = [movie_id, person_id, member['character'], member['order'] + 1].join("\t")
        @conn.put_copy_data "#{row}\n"
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Cast for movie ##{movie_id} already linked.")
  end

  def link_crew_bulk(movie_id, crew_data, people_map)
    directors = crew_data.select { |c| c['job'] == 'Director' }
    writers = crew_data.select { |c| ['Screenplay', 'Writer', 'Story'].include?(c['job']) }
    director_ids = directors.map { |d| people_map[d['id']] }.compact
    writer_ids = writers.map { |w| people_map[w['id']] }.compact
    link_generic_bulk('movie_directors', 'movie_id', 'person_id', movie_id, director_ids)
    link_generic_bulk('movie_writers', 'movie_id', 'person_id', movie_id, writer_ids)
  end

  def get_or_create_franchise(collection_data)
    return nil unless collection_data && collection_data['name']
    get_or_create_generic('franchises', 'franchise_name', 'franchise_id', collection_data['name'])
  end

  def get_or_create_resolution(width, height)
    return nil unless width && height > 0
    sql = 'SELECT resolution_id FROM video_resolutions WHERE width_pixels = $1 AND height_pixels = $2'
    res = @conn.exec_params(sql, [width, height])
    return res.first['resolution_id'] if res.ntuples > 0
    name = case height
           when 2160.. then '4K'
           when 1080 then '1080p'
           when 720 then '720p'
           when 480 then '480p'
           else "#{height}p"
           end
    insert_sql = 'INSERT INTO video_resolutions (resolution_name, width_pixels, height_pixels) VALUES ($1, $2, $3) RETURNING resolution_id'
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
