# frozen_string_literal: true
class SeriesService
  class << self
    def filtered(filters)
      sql = <<~SQL
        SELECT
          s.series_id, s.series_name, s.original_name, s.first_air_date,
          s.last_air_date, s.status, s.rating, s.poster_path,
          s.tmdb_id,
          COALESCE(ARRAY_AGG(DISTINCT g.genre_name) FILTER (WHERE g.genre_name IS NOT NULL), '{}') AS genres
        FROM series s
        LEFT JOIN series_genres sg ON sg.series_id = s.series_id
        LEFT JOIN genres g ON g.genre_id = sg.genre_id
        WHERE 1=1
      SQL
      args = []
      if filters[:search] && !filters[:search].empty?
        sql << ' AND (s.series_name ILIKE ? OR s.original_name ILIKE ?)'
        args << "%#{filters[:search]}%" << "%#{filters[:search]}%"
      end
      if filters[:genre] && !filters[:genre].empty?
        sql << ' AND g.genre_name = ?'
        args << filters[:genre]
      end
      sql << ' GROUP BY s.series_id'
      sql << ' ORDER BY s.series_name'
      DB.fetch(sql, *args).all
    end

    def find(series_id)
      series = DB.fetch(<<~SQL, series_id).first
        SELECT
          s.*, COALESCE(ARRAY_AGG(DISTINCT g.genre_name) FILTER (WHERE g.genre_name IS NOT NULL), '{}') AS genres
        FROM series s
        LEFT JOIN series_genres sg ON sg.series_id = s.series_id
        LEFT JOIN genres g ON g.genre_id = sg.genre_id
        WHERE s.series_id = ?
        GROUP BY s.series_id
      SQL
      return nil unless series

      seasons = DB[:seasons].where(series_id: series_id).order(:season_number).all
      seasons.each do |season|
        season[:episodes] = DB[:episodes].where(season_id: season[:season_id]).order(:episode_number).all
      end
      series[:seasons] = seasons
      series
    end

    def recent(limit = 10)
      DB[:series].order(Sequel.desc(:created_at)).limit(limit).all
    end
  end
end
