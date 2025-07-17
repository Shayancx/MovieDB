require_relative '../db'

class MovieService
  class << self
    def list
      DB.fetch(<<~SQL
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

    def filtered(filters)
      sql = <<~SQL
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
        WHERE 1=1
      SQL
      args = []
      if filters[:search] && !filters[:search].empty?
        sql << " AND (m.movie_name ILIKE ? OR m.original_title ILIKE ?)"
        args << "%#{filters[:search]}%" << "%#{filters[:search]}%"
      end
      if filters[:genre] && !filters[:genre].empty?
        sql << " AND g.genre_name = ?"
        args << filters[:genre]
      end
      if filters[:country] && !filters[:country].empty?
        sql << " AND c.country_name = ?"
        args << filters[:country]
      end
      if filters[:language] && !filters[:language].empty?
        sql << " AND l.language_name = ?"
        args << filters[:language]
      end
      if filters[:franchise] && !filters[:franchise].empty?
        sql << " AND m.franchise_id = ?"
        args << filters[:franchise]
      end
      if filters[:year] && !filters[:year].empty?
        sql << " AND EXTRACT(YEAR FROM m.release_date) = ?"
        args << filters[:year].to_i
      end
      sql << " GROUP BY m.movie_id, f.franchise_name"
      sort_by = case filters[:sort_by]
                when 'date' then 'm.release_date'
                when 'rating' then 'm.rating'
                when 'runtime' then 'm.runtime_minutes'
                else 'm.movie_name'
                end
      order = filters[:sort_order] == 'desc' ? 'DESC' : 'ASC'
      sql << " ORDER BY #{sort_by} #{order}"

      DB.fetch(sql, *args).all
    end

    def find(movie_id)
      movie = DB.fetch(<<~SQL, movie_id).first
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
      return nil unless movie

      movie[:directors] = DB[:movie_directors]
        .join(:people, person_id: :person_id)
        .where(Sequel[:movie_directors][:movie_id] => movie_id)
        .select_map(:full_name)

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

    def genres
      DB[:genres].order(:genre_name).all
    end

    def countries
      DB[:countries].order(:country_name).all
    end

    def languages
      DB[:languages].order(:language_name).all
    end

    def franchises
      DB[:franchises].order(:franchise_name).all
    end

    def years
      DB[:movies]
        .exclude(release_date: nil)
        .select{extract(:year, :release_date).as(:year)}
        .distinct
        .order(Sequel.desc(:year))
        .map { |r| r[:year].to_i }
    end
  end
end
