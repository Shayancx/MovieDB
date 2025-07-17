# frozen_string_literal: true

require_relative '../db'

class StatisticsService
  class << self
    def summary
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
                        .where { release_date !~ nil }
                        .group_and_count(Sequel.function(:date_part, 'year', :release_date))
                        .order(Sequel.desc(Sequel.function(:date_part, 'year', :release_date)))
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
