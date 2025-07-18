# frozen_string_literal: true

require_relative '../db'

# Provides methods for calculating and retrieving application statistics.
class StatisticsService
  class << self
    # Returns a summary of all statistics.
    def summary
      {
        total_movies: total_movies,
        total_size_gb: total_size_gb,
        total_runtime_hours: total_runtime_hours,
        movies_per_genre: movies_per_genre,
        movies_per_year: movies_per_year
      }
    end

    private

    # Calculates the total number of movies.
    def total_movies
      DB[:movies].count
    rescue Sequel::DatabaseError => e
      handle_error(e, 0)
    end

    # Calculates the total size of all movie files in gigabytes.
    def total_size_gb
      total_size_mb = DB[:movie_files].sum(:file_size_mb)
      total_size_mb ? (total_size_mb / 1024.0).round(2) : 0
    rescue Sequel::DatabaseError => e
      handle_error(e, 0)
    end

    # Calculates the total runtime of all movies in hours.
    def total_runtime_hours
      total_runtime_minutes = DB[:movies].sum(:runtime_minutes)
      total_runtime_minutes ? (total_runtime_minutes / 60.0).round : 0
    rescue Sequel::DatabaseError => e
      handle_error(e, 0)
    end

    # Retrieves the top 10 genres by movie count.
    def movies_per_genre
      DB[:movie_genres]
        .join(:genres, genre_id: :genre_id)
        .group_and_count(:genre_name)
        .order(Sequel.desc(:count))
        .limit(10)
        .all
    rescue Sequel::DatabaseError => e
      handle_error(e, [])
    end

    # Retrieves the number of movies released per year.
    def movies_per_year
      DB[:movies]
        .where(Sequel.lit('release_date IS NOT NULL'))
        .group_and_count(Sequel.function(:strftime, '%Y', :release_date))
        .order(Sequel.desc(:count))
        .all
    rescue Sequel::DatabaseError => e
      handle_error(e, [])
    end

    # Handles database errors gracefully.
    def handle_error(error, default_value)
      PrettyLogger.error("StatisticsService error: #{error.message}")
      default_value
    end
  end
end