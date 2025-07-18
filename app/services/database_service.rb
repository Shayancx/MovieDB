# frozen_string_literal: true

require 'set'
require_relative '../db'
require_relative 'pretty_logger'

# Handles all database interactions for the application.
class DatabaseService
  attr_reader :conn

  def initialize
    @conn = DB
  end

  # Fetches the set of all existing movie file paths from the database.
  def get_existing_file_paths
    @conn[:movie_files].select_map(:file_path).to_set
  end

  # Inserts or updates a movie, returning the movie_id.
  def insert_movie(details)
    franchise_id = get_or_create_franchise(details['belongs_to_collection'])
    @conn[:movies].insert_conflict(
      target: :tmdb_id,
      update: {
        movie_name: Sequel[:excluded][:movie_name],
        original_title: Sequel[:excluded][:original_title],
        release_date: Sequel[:excluded][:release_date],
        description: Sequel[:excluded][:description],
        runtime_minutes: Sequel[:excluded][:runtime_minutes],
        imdb_id: Sequel[:excluded][:imdb_id],
        rating: Sequel[:excluded][:rating]
      }
    ).insert(
      movie_name: details['title'],
      original_title: details['original_title'],
      release_date: details['release_date'],
      description: details['overview'],
      runtime_minutes: details['runtime'],
      imdb_id: details['imdb_id'],
      tmdb_id: details['id'],
      rating: details['vote_average']&.round(1),
      franchise_id: franchise_id
    )
    @conn[:movies].where(tmdb_id: details['id']).get(:movie_id)
  end

  # Inserts a movie file record, returning the file_id.
  def insert_movie_file(movie_id, file_path, mediainfo)
    @conn[:movie_files].insert_conflict(target: :file_path, update: {}).insert(
      movie_id: movie_id,
      file_path: File.absolute_path(file_path),
      file_name: File.basename(file_path),
      file_format: mediainfo.file_format,
      file_size_mb: mediainfo.file_size_mb,
      duration_minutes: mediainfo.duration_minutes,
      video_codec_id: get_or_create_generic('video_codecs', 'codec_name', mediainfo.video_codec),
      resolution_id: get_or_create_resolution(mediainfo.width, mediainfo.height),
      source_media_type_id: get_or_create_generic('source_media_types', 'source_type_name', guess_source_media_type(file_path)),
      video_bitrate_kbps: mediainfo.video_bitrate_kbps,
      frame_rate_fps: mediainfo.frame_rate,
      aspect_ratio: mediainfo.aspect_ratio
    )
    @conn[:movie_files].where(file_path: File.absolute_path(file_path)).get(:file_id)
  end

  # Bulk imports all associations for a movie (cast, crew, genres, etc.).
  def bulk_import_associations(movie_id, details)
    people_map = get_or_create_people_bulk(details)
    link_cast_bulk(movie_id, details.dig('credits', 'cast'), people_map)
    link_crew_bulk(movie_id, details.dig('credits', 'crew'), people_map)
    link_genres_bulk(movie_id, details['genres'])
    link_countries_bulk(movie_id, details['production_countries'])
    link_languages_bulk(movie_id, details['spoken_languages'])
    people_map
  end

  # Updates a single record in a given table.
  def update_record(table, id, data)
    id_column = "#{table.to_s.chomp('s')}_id".to_sym
    @conn[table].where(id_column => id).update(data)
  rescue Sequel::DatabaseError => e
    PrettyLogger.error("DB update failed for #{table}##{id}: #{e.message}")
  end

  # Closes the database connection.
  def close
    @conn.disconnect if @conn&.respond_to?(:disconnect)
  end

  private

  # Gets or creates people in bulk and returns a map of TMDB ID to database ID.
  def get_or_create_people_bulk(details)
    people = (details.dig('credits', 'cast') || []) + (details.dig('credits', 'crew') || [])
    return {} if people.empty?

    people_data = people.uniq { |p| p['id'] }.map { |p| { tmdb_person_id: p['id'], full_name: p['name'] } }
    @conn[:people].insert_ignore.multi_insert(people_data)

    tmdb_ids = people_data.map { |p| p[:tmdb_person_id] }
    @conn[:people].where(tmdb_person_id: tmdb_ids).select_map([:tmdb_person_id, :person_id]).to_h
  end

  # Links cast members to a movie.
  def link_cast_bulk(movie_id, cast_data, people_map)
    return if cast_data.blank?
    cast_records = cast_data.map do |member|
      {
        movie_id: movie_id,
        person_id: people_map[member['id']],
        character_name: member['character'],
        billing_order: member['order']
      }
    end.compact
    @conn[:movie_cast].insert_ignore.multi_insert(cast_records)
  end

  # Links crew members (directors, writers) to a movie.
  def link_crew_bulk(movie_id, crew_data, people_map)
    return if crew_data.blank?
    director_ids = crew_data.select { |c| c['job'] == 'Director' }.map { |c| people_map[c['id']] }.compact
    writer_ids = crew_data.select { |c| c['job'] == 'Writer' }.map { |c| people_map[c['id']] }.compact

    link_generic_bulk(:movie_directors, :movie_id, :person_id, movie_id, director_ids)
    link_generic_bulk(:movie_writers, :movie_id, :person_id, movie_id, writer_ids)
  end

  # Links genres to a movie.
  def link_genres_bulk(movie_id, genres)
    return if genres.blank?
    genre_names = genres.map { |g| g['name'] }
    genre_ids = get_or_create_generic_bulk(:genres, :genre_name, genre_names)
    link_generic_bulk(:movie_genres, :movie_id, :genre_id, movie_id, genre_ids)
  end

  # Links production countries to a movie.
  def link_countries_bulk(movie_id, countries)
    return if countries.blank?
    country_names = countries.map { |c| c['name'] }
    country_ids = get_or_create_generic_bulk(:production_countries, :country_name, country_names)
    link_generic_bulk(:movie_countries, :movie_id, :country_id, movie_id, country_ids)
  end

  # Links spoken languages to a movie.
  def link_languages_bulk(movie_id, languages)
    return if languages.blank?
    lang_names = languages.map { |l| l['english_name'] }
    lang_ids = get_or_create_generic_bulk(:languages, :language_name, lang_names)
    link_generic_bulk(:movie_languages, :movie_id, :language_id, movie_id, lang_ids)
  end

  # Generic method to link a movie to a list of other IDs in a join table.
  def link_generic_bulk(table, movie_col, other_col, movie_id, other_ids)
    return if other_ids.blank?
    records = other_ids.uniq.map { |other_id| { movie_col => movie_id, other_col => other_id } }
    @conn[table].insert_ignore.multi_insert(records)
  end

  # Gets or creates multiple generic records (e.g., genres, keywords).
  def get_or_create_generic_bulk(table, name_col, names)
    return [] if names.blank?
    @conn[table].insert_ignore.multi_insert(names.map { |name| { name_col => name } })
    @conn[table].where(name_col => names).select_map("#{table.to_s.chomp('s')}_id".to_sym)
  end

  # Gets or creates a single generic record.
  def get_or_create_generic(table, name_col, name)
    return nil if name.blank?
    id_col = "#{table.to_s.chomp('s')}_id".to_sym
    @conn[table].first(name_col => name)&.dig(id_col) ||
      @conn[table].insert(name_col => name)
  end

  # Gets or creates a video resolution record.
  def get_or_create_resolution(width, height)
    return nil unless width.to_i.positive? && height.to_i.positive?
    @conn[:video_resolutions].first(width_pixels: width, height_pixels: height)&.dig(:resolution_id) ||
      @conn[:video_resolutions].insert(width_pixels: width, height_pixels: height, resolution_name: "#{height}p")
  end

  # Gets or creates a franchise record from TMDB collection data.
  def get_or_create_franchise(collection_data)
    return nil if collection_data.blank?
    get_or_create_generic(:franchises, :franchise_name, collection_data['name'])
  end

  # Guesses the source media type from the filename.
  def guess_source_media_type(file_path)
    case File.basename(file_path).downcase
    when /blu-?ray|bluray|bdremux|bdmux/ then 'Blu-ray'
    when /4k|uhd/ then '4K Blu-ray'
    when /dvd/ then 'DVD'
    when /web-?dl/ then 'Web-DL'
    when /web-?rip/ then 'WEB-Rip'
    else 'Digital'
    end
  end
end

class String
  def blank?
    strip.empty?
  end
end

class NilClass
  def blank?
    true
  end
end

class Array
  def blank?
    empty?
  end
end
