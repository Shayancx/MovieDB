# frozen_string_literal: true

require 'set'
require_relative '../db'
require_relative 'pretty_logger'

class DatabaseService
  attr_reader :conn

  def initialize(_config_file = nil)
    @conn = DB
  end

  def get_existing_file_paths
    DB[:movie_files].select(:file_path).map { |row| row[:file_path] }.to_set
  end

  def insert_movie(details)
    franchise_id = get_or_create_franchise(details['belongs_to_collection'])
    sql = <<~SQL
      INSERT INTO movies (movie_name, original_title, release_date, description, runtime_minutes, imdb_id, tmdb_id, rating, franchise_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    DB[sql,
       details['title'],
       details['original_title'],
       details['release_date'],
       details['overview'],
       details['runtime'],
       details['imdb_id'],
       details['id'],
       details['vote_average']&.round(1),
       franchise_id].get(:movie_id).to_i
  end

  def insert_series(details)
    franchise_id = get_or_create_franchise(details['belongs_to_collection'])
    sql = <<~SQL
      INSERT INTO series (series_name, original_name, first_air_date, last_air_date, status, description, imdb_id, tmdb_id, franchise_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (tmdb_id) DO UPDATE SET
        series_name = EXCLUDED.series_name,
        original_name = EXCLUDED.original_name,
        first_air_date = EXCLUDED.first_air_date,
        last_air_date = EXCLUDED.last_air_date,
        status = EXCLUDED.status,
        description = EXCLUDED.description,
        imdb_id = EXCLUDED.imdb_id
      RETURNING series_id
    SQL
    DB[sql,
       details['name'],
       details['original_name'],
       details['first_air_date'],
       details['last_air_date'],
       details['status'],
       details['overview'],
       details.dig('external_ids', 'imdb_id'),
       details['id'],
       franchise_id].get(:series_id).to_i
  end

  def bulk_import_series_associations(series_id, details)
    cast_data = (details.dig('aggregate_credits', 'cast') || []).first(50)
    crew_data = details.dig('aggregate_credits', 'crew') || []
    people_data = (cast_data + crew_data).uniq { |p| p['id'] }
    people_map = get_or_create_people_bulk(people_data)
    link_series_cast_bulk(series_id, cast_data, people_map)
    link_series_crew_bulk(series_id, crew_data, people_map)

    genre_names = (details['genres'] || []).map { |g| g['name'] }
    genre_ids = get_or_create_generic_bulk('genres', 'genre_name', 'genre_id', genre_names)
    link_generic_bulk('series_genres', 'series_id', 'genre_id', series_id, genre_ids)

    people_map
  end

  def insert_movie_file(movie_id, file_path, mediainfo)
    resolution_id = get_or_create_resolution(mediainfo.width, mediainfo.height)
    video_codec_id = get_or_create_generic('video_codecs', 'codec_name', 'codec_id', mediainfo.video_codec)
    source_type_id = get_or_create_generic('source_media_types', 'source_type_name', 'source_type_id',
                                           guess_source_media_type(file_path))
    sql = <<~SQL
      INSERT INTO movie_files (movie_id, file_name, file_path, file_format, file_size_mb, resolution_id, video_bitrate_kbps, video_codec_id, frame_rate_fps, aspect_ratio, duration_minutes, source_media_type_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (file_path) DO NOTHING
      RETURNING file_id
    SQL
    DB[sql,
       movie_id,
       File.basename(file_path),
       File.absolute_path(file_path),
       mediainfo.file_format,
       mediainfo.file_size_mb,
       resolution_id,
       mediainfo.video_bitrate_kbps,
       video_codec_id,
       mediainfo.frame_rate,
       mediainfo.aspect_ratio,
       mediainfo.duration_minutes,
       source_type_id].get(:file_id)&.to_i
  end

  def bulk_import_associations(movie_id, details)
    cast_data = (details.dig('credits', 'cast') || []).first(50)
    crew_data = details.dig('credits', 'crew') || []
    people_data = (cast_data + crew_data).uniq { |p| p['id'] }
    people_map = get_or_create_people_bulk(people_data)
    link_cast_bulk(movie_id, cast_data, people_map)
    link_crew_bulk(movie_id, crew_data, people_map)

    genre_names = (details['genres'] || []).map { |g| g['name'] }
    genre_ids = get_or_create_generic_bulk('genres', 'genre_name', 'genre_id', genre_names)
    link_generic_bulk('movie_genres', 'movie_id', 'genre_id', movie_id, genre_ids)

    country_data = (details['production_countries'] || []).map { |c| [c['iso_3166_1'], c['name']] }
    country_ids = get_or_create_code_name_bulk('production_countries', 'iso_3166_1_code', 'country_name', 'country_id',
                                               country_data)
    link_generic_bulk('movie_countries', 'movie_id', 'country_id', movie_id, country_ids)

    lang_data = (details['spoken_languages'] || []).map { |l| [l['iso_639_1'], l['english_name']] }
    lang_ids = get_or_create_code_name_bulk('languages', 'iso_639_1_code', 'language_name', 'language_id', lang_data)
    link_generic_bulk('movie_languages', 'movie_id', 'language_id', movie_id, lang_ids)

    people_map
  end

  def update_record(table:, id_col:, id_val:, data:)
    DB[table.to_sym].where(id_col.to_sym => id_val).update(data)
    PrettyLogger.debug("DB updated for #{table}##{id_val}")
  rescue Sequel::DatabaseError => e
    PrettyLogger.error("DB update failed for #{table}##{id_val}: #{e.message}")
  end

  def close
    @conn.disconnect if @conn.respond_to?(:disconnect)
  end

  private

  def get_or_create_generic_bulk(table, name_col, id_col, names)
    return [] if names.empty?

    sql = <<~SQL
      WITH new_names (name) AS (
        SELECT * FROM unnest(?::text[])
      ),
      ins AS (
        INSERT INTO #{table} (#{name_col})
        SELECT name FROM new_names
        ON CONFLICT (#{name_col}) DO NOTHING
        RETURNING #{id_col}, #{name_col}
      )
      SELECT #{id_col}, #{name_col} FROM ins
      UNION ALL
      SELECT #{id_col}, #{name_col} FROM #{table} WHERE #{name_col} = ANY(?)
    SQL
    array = Sequel.pg_array(names)
    DB[sql, array, array].map { |r| r[id_col.to_sym] }
  end

  def get_or_create_code_name_bulk(table, code_col, name_col, id_col, data)
    return [] if data.empty?

    codes = data.map(&:first)
    sql = <<~SQL
      WITH new_items (code, name) AS (
        SELECT * FROM unnest(?::text[], ?::text[])
      ),
      ins AS (
        INSERT INTO #{table} (#{code_col}, #{name_col})
        SELECT code, name FROM new_items
        ON CONFLICT (#{code_col}) DO NOTHING
        RETURNING #{id_col}, #{code_col}
      )
      SELECT #{id_col}, #{code_col} FROM ins
      UNION ALL
      SELECT #{id_col}, #{code_col} FROM #{table} WHERE #{code_col} = ANY(?)
    SQL
    codes_array = Sequel.pg_array(codes)
    names_array = Sequel.pg_array(data.map(&:last))
    DB[sql, codes_array, names_array, codes_array].map { |r| r[id_col.to_sym] }
  end

  def get_or_create_people_bulk(people)
    return {} if people.empty?

    tmdb_ids = people.map { |p| p['id'] }
    sql = <<~SQL
      WITH new_people (tmdb_id, full_name) AS (
        SELECT * FROM unnest(?::int[], ?::text[])
      ),
      ins AS (
        INSERT INTO people (tmdb_id, full_name)
        SELECT tmdb_id, full_name FROM new_people
        ON CONFLICT (tmdb_id) DO NOTHING
        RETURNING person_id, tmdb_id
      )
      SELECT person_id, tmdb_id FROM ins
      UNION ALL
      SELECT person_id, tmdb_id FROM people WHERE tmdb_id = ANY(?)
    SQL
    ids_array = Sequel.pg_array(tmdb_ids)
    names_array = Sequel.pg_array(people.map { |p| p['name'] })
    DB[sql, ids_array, names_array, ids_array]
      .each_with_object({}) { |r, h| h[r[:tmdb_id].to_i] = r[:person_id].to_i }
  end

  def link_generic_bulk(link_table, movie_id_col, other_id_col, movie_id, other_ids)
    return if other_ids.empty?

    DB.synchronize do |c|
      c.copy_data "COPY #{link_table} (#{movie_id_col}, #{other_id_col}) FROM STDIN" do
        other_ids.uniq.each do |other_id|
          c.put_copy_data "#{movie_id}\t#{other_id}\n"
        end
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Links for #{link_table} and movie ##{movie_id} may already exist.")
  end

  def link_cast_bulk(movie_id, cast_data, people_map)
    return if cast_data.empty?

    DB.synchronize do |c|
      c.copy_data 'COPY movie_cast (movie_id, person_id, character_name, billing_order) FROM STDIN' do
        cast_data.each do |member|
          person_id = people_map[member['id']]
          next unless person_id && member['character']

          row = [movie_id, person_id, member['character'], member['order'] + 1].join("\t")
          c.put_copy_data "#{row}\n"
        end
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Cast for movie ##{movie_id} already linked.")
  end

  def link_crew_bulk(movie_id, crew_data, people_map)
    directors = crew_data.select { |c| c['job'] == 'Director' }
    writers = crew_data.select { |c| %w[Screenplay Writer Story].include?(c['job']) }
    director_ids = directors.map { |d| people_map[d['id']] }.compact
    writer_ids = writers.map { |w| people_map[w['id']] }.compact
    link_generic_bulk('movie_directors', 'movie_id', 'person_id', movie_id, director_ids)
    link_generic_bulk('movie_writers', 'movie_id', 'person_id', movie_id, writer_ids)
  end

  def link_series_cast_bulk(series_id, cast_data, people_map)
    return if cast_data.empty?

    DB.synchronize do |c|
      c.copy_data 'COPY series_cast (series_id, person_id, character_name, billing_order) FROM STDIN' do
        cast_data.each do |member|
          person_id = people_map[member['id']]
          next unless person_id && member['character']

          row = [series_id, person_id, member['character'], member['order'] + 1].join("\t")
          c.put_copy_data "#{row}\n"
        end
      end
    end
  rescue PG::UniqueViolation
    PrettyLogger.debug("Cast for series ##{series_id} already linked.")
  end

  def link_series_crew_bulk(series_id, crew_data, people_map)
    creators = crew_data.select { |c| c['job'] == 'Creator' }
    creator_ids = creators.map { |c| people_map[c['id']] }.compact
    link_generic_bulk('series_creators', 'series_id', 'person_id', series_id, creator_ids)
  end

  def get_or_create_franchise(collection_data)
    return nil unless collection_data && collection_data['name']

    get_or_create_generic('franchises', 'franchise_name', 'franchise_id', collection_data['name'])
  end

  def get_or_create_resolution(width, height)
    return nil unless width.to_i.positive? && height.to_i.positive?

    res = DB[:video_resolutions].where(width_pixels: width, height_pixels: height).get(:resolution_id)
    return res if res

    name = case height
           when 2160.. then '4K'
           when 1080 then '1080p'
           when 720 then '720p'
           when 480 then '480p'
           else "#{height}p"
           end
    insert_sql = 'INSERT INTO video_resolutions (resolution_name, width_pixels, height_pixels) VALUES (?, ?, ?) RETURNING resolution_id'
    DB[insert_sql, name, width, height].get(:resolution_id)
  end

  def get_or_create_generic(table, name_col, id_col, name)
    return nil if name.nil? || name.to_s.strip.empty?

    id = DB[table.to_sym].where(name_col.to_sym => name).get(id_col.to_sym)
    return id if id

    insert_sql = "INSERT INTO #{table} (#{name_col}) VALUES (?) ON CONFLICT(#{name_col}) DO UPDATE SET #{name_col}=EXCLUDED.#{name_col} RETURNING #{id_col}"
    DB[insert_sql, name].get(id_col.to_sym)
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
