#!/usr/bin/env ruby
require_relative 'config/environment'
require 'roda'
require 'sequel'
require 'json'

# --- DATABASE CONNECTION WITH ERROR HANDLING ---
begin
  DB = Sequel.connect(
    adapter: 'postgres',
    host: ENV['DB_HOST'] || 'localhost',
    port: ENV['DB_PORT'] || 5432,
    database: ENV['DB_NAME'] || 'MovieDB',
    user: ENV['DB_USER'] || 'shayan',
    password: ENV['DB_PASSWORD'] || ''
  )
  DB.extension :pg_array
  DB.test_connection
rescue Sequel::DatabaseConnectionError => e
  puts "=" * 80, "DATABASE CONNECTION FAILED", "=" * 80
  puts "Could not connect to the PostgreSQL database."
  puts "Please check your configuration."
  puts "Error details: #{e.message}"
  puts "=" * 80
  exit 1
end
# --- END OF DATABASE CONNECTION HANDLING ---


class MovieExplorer < Roda
  plugin :json
  plugin :all_verbs
  plugin :halt
  
  
  
  plugin :not_found do
    if request.path.start_with?('/api/')
      response.status = 404
      response['Content-Type'] = 'application/json'
      { error: 'API route not found' }
    else
      # For any other path, serve the main index.html to let the frontend handle routing.
      response['Content-Type'] = 'text/html'
      File.read('index.html')
    end
  end
  
  plugin :error_handler do |e|
    warn "Error: #{e.message}"
    warn e.backtrace.join("\n")
    response.status = 500
    response['Content-Type'] = 'application/json'
    { error: 'Internal server error' }
  end

  plugin :default_headers,
    'Access-Control-Allow-Origin' => '*',
    'Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers' => 'Content-Type, Authorization'

  route do |r|
    r.on method: :options do
      response.status = 204
      ""
    end

    r.root do
      response['Content-Type'] = 'text/html'
      File.read('index.html')
    end

    r.on 'api' do
      response['Content-Type'] = 'application/json'
      
      r.get 'movies' do
        DB.fetch(<<-SQL
          SELECT 
            m.movie_id, m.movie_name, m.original_title, m.release_date,
            m.runtime_minutes, m.rating, m.franchise_id, m.poster_path,
            m.imdb_id, m.tmdb_id,
            f.franchise_name,
            COALESCE(ARRAY_AGG(DISTINCT g.genre_name) FILTER (WHERE g.genre_name IS NOT NULL), '{}') AS genres,
            COALESCE(ARRAY_AGG(DISTINCT c.country_name) FILTER (WHERE c.country_name IS NOT NULL), '{}') AS countries,
            COALESCE(ARRAY_AGG(DISTINCT l.language_name) FILTER (WHERE l.language_name IS NOT NULL), '{}') AS languages
          FROM movies m
          LEFT JOIN franchises f ON f.franchise_id = m.franchise_id
          LEFT JOIN movie_genres mg ON mg.movie_id = m.movie_id
          LEFT JOIN genres g ON g.genre_id = mg.genre_id
          LEFT JOIN movie_countries mc ON mc.movie_id = m.movie_id
          LEFT JOIN countries c ON c.country_id = mc.country_id
          LEFT JOIN movie_languages ml ON ml.movie_id = m.movie_id
          LEFT JOIN languages l ON l.language_id = ml.language_id
          GROUP BY m.movie_id, f.franchise_name
          ORDER BY m.movie_name
        SQL
        ).all
      end

      r.get 'movie', Integer do |movie_id|
        movie = DB.fetch(<<-SQL, movie_id).first
          SELECT 
            m.movie_id, m.movie_name, m.original_title, m.release_date,
            m.runtime_minutes, m.rating, m.description,
            m.poster_path, m.backdrop_path, m.imdb_id, m.tmdb_id,
            f.franchise_name,
            COALESCE(ARRAY_AGG(DISTINCT g.genre_name) FILTER (WHERE g.genre_name IS NOT NULL), '{}') AS genres,
            COALESCE(ARRAY_AGG(DISTINCT c.country_name) FILTER (WHERE c.country_name IS NOT NULL), '{}') AS countries,
            COALESCE(ARRAY_AGG(DISTINCT l.language_name) FILTER (WHERE l.language_name IS NOT NULL), '{}') AS languages,
            COALESCE(ARRAY_AGG(DISTINCT cert.certification_code) FILTER (WHERE cert.certification_code IS NOT NULL), '{}') AS certifications
          FROM movies m
          LEFT JOIN franchises f ON f.franchise_id = m.franchise_id
          LEFT JOIN movie_genres mg ON mg.movie_id = m.movie_id
          LEFT JOIN genres g ON g.genre_id = mg.genre_id
          LEFT JOIN movie_countries mc ON mc.movie_id = m.movie_id
          LEFT JOIN countries c ON c.country_id = mc.country_id
          LEFT JOIN movie_languages ml ON ml.movie_id = m.movie_id
          LEFT JOIN languages l ON l.language_id = ml.language_id
          LEFT JOIN movie_certifications mct ON mct.movie_id = m.movie_id
          LEFT JOIN certifications cert ON cert.certification_id = mct.certification_id
          WHERE m.movie_id = ?
          GROUP BY m.movie_id, f.franchise_name
        SQL

        r.halt(404, { error: 'Movie not found' }) unless movie

        movie[:directors] = DB[:movie_directors].join(:people, person_id: :person_id).where(Sequel[:movie_directors][:movie_id] => movie_id).select_map(:full_name)
        
        movie[:writers] = DB[:movie_writers]
          .join(:people, person_id: Sequel[:movie_writers][:person_id])
          .join(:credit_types, credit_type_id: Sequel[:movie_writers][:credit_type_id])
          .where(Sequel[:movie_writers][:movie_id] => movie_id)
          .select(Sequel[:people][:person_id], Sequel[:people][:full_name], Sequel[:credit_types][:credit_type_name])
          .all

        movie[:cast] = DB[:movie_cast]
          .join(:people, person_id: Sequel[:movie_cast][:person_id])
          .left_join(:role_types, role_type_id: Sequel[:movie_cast][:role_type_id])
          .where(Sequel[:movie_cast][:movie_id] => movie_id)
          .order(:billing_order)
          .select(:cast_id, Sequel[:people][:person_id], :full_name, :character_name, :billing_order, :role_name, :headshot_path)
          .all
        
        files = DB[:movie_files]
          .left_join(:video_resolutions, resolution_id: Sequel[:movie_files][:resolution_id])
          .left_join(:video_codecs, codec_id: Sequel[:movie_files][:video_codec_id])
          .left_join(:source_media_types, source_type_id: Sequel[:movie_files][:source_media_type_id])
          .where(Sequel[:movie_files][:movie_id] => movie_id)
          .order(:file_name)
          .all
          
        files.each do |file|
          file[:audio_tracks] = DB[:movie_file_audio_tracks]
            .left_join(:audio_codecs, codec_id: Sequel[:movie_file_audio_tracks][:audio_codec_id])
            .left_join(:languages, language_id: Sequel[:movie_file_audio_tracks][:language_id])
            .where(file_id: file[:file_id])
            .order(:track_order)
            .all
          
          file[:subtitles] = DB[:movie_file_subtitles]
            .join(:languages, language_id: Sequel[:movie_file_subtitles][:language_id])
            .where(file_id: file[:file_id])
            .order(:track_order)
            .all
        end
        movie[:files] = files

        movie
      end

      r.get 'genres' do
        DB[:genres].order(:genre_name).all
      end

      r.get 'countries' do
        DB[:countries].order(:country_name).all
      end

      r.get 'languages' do
        DB[:languages].order(:language_name).all
      end

      r.get 'franchises' do
        DB[:franchises].order(:franchise_name).all
      end

      r.get 'person', Integer do |person_id|
        person = DB[:people].where(person_id: person_id).first
        r.halt(404, { error: 'Person not found' }) unless person

        person[:movies] = DB[:movie_cast]
          .join(:movies, movie_id: :movie_id)
          .where(Sequel[:movie_cast][:person_id] => person_id)
          .order(Sequel.desc(:release_date))
          .select(Sequel[:movies][:movie_id], :movie_name, :release_date, :character_name, :poster_path)
          .all
        person
      end

      r.get 'statistics' do
        total_movies = DB[:movies].count
        total_size_mb = DB[:movie_files].sum(:file_size_mb)
        total_runtime_minutes = DB[:movies].sum(:runtime_minutes)

        movies_per_genre = DB[:movie_genres]
          .join(:genres, genre_id: :genre_id)
          .group_and_count(:genre_name)
          .order(Sequel.desc(:count))
          .limit(10)
          .all

        movies_per_year = DB[:movies]
          .where{release_date !~ nil}
          .group_and_count(Sequel.extract(:year, :release_date))
          .order(Sequel.desc(Sequel.extract(:year, :release_date)))
          .all

        {
          total_movies: total_movies,
          total_size_gb: total_size_mb ? (total_size_mb / 1024.0).round(2) : 0,
          total_runtime_hours: total_runtime_minutes ? (total_runtime_minutes / 60.0).round : 0,
          movies_per_genre: movies_per_genre,
          movies_per_year: movies_per_year
        }
      end
    end
  end
end