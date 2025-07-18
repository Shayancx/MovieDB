# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'open-uri'
require 'fileutils'
require_relative 'pretty_logger'
require_relative 'import_config'

# A client for interacting with The Movie Database (TMDB) API.
class TmdbClient
  include ImportConfig

  # Custom error for rate limiting to control retry logic.
  class RateLimitError < StandardError; end

  # Initializes the client, setting up a persistent HTTP connection.
  def initialize
    uri = URI(TMDB_API_BASE_URL)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    @http.open_timeout = 10 # seconds
    @http.read_timeout = 30 # seconds
  end

  # Searches for movies by name and optional year.
  def search_movie(name, year)
    params = { query: name, year: year }.compact
    response = make_api_request('/search/movie', params)
    response&.dig('results') || []
  end

  # Fetches detailed information for a specific movie.
  def get_movie_details(tmdb_id)
    make_api_request("/movie/#{tmdb_id}", append_to_response: 'credits,release_dates,images')
  end

  # Downloads an image from TMDB and saves it locally.
  def download_image(api_path, relative_save_path)
    return nil if api_path.blank?

    source_url = "#{TMDB_IMAGE_BASE_URL}#{api_path}"
    absolute_save_path = File.join(MEDIA_BASE_DIR, relative_save_path)

    return relative_save_path if File.exist?(absolute_save_path)

    PrettyLogger.info("Downloading image: #{api_path} -> #{relative_save_path}")

    # Create the directory and then check for writability
    parent_dir = File.dirname(absolute_save_path)
    FileUtils.mkdir_p(parent_dir)
    unless File.writable?(parent_dir)
      PrettyLogger.error("Directory not writable: #{parent_dir}")
      return nil
    end

    retry_with_backoff do
      URI.open(source_url) do |image|
        File.open(absolute_save_path, 'wb') { |file| file.write(image.read) }
      end
    end

    relative_save_path
  rescue StandardError => e
    PrettyLogger.warn("Failed to download image from #{source_url}: #{e.message}")
    nil
  end

  private

  # Makes an API request with retry logic for network errors and rate limiting.
  def make_api_request(path, params = {})
    retry_with_backoff do
      uri = build_uri(path, params)
      request = Net::HTTP::Get.new(uri)
      response = @http.request(request)

      handle_api_response(response)
    end
  rescue RateLimitError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET
    # This block will be entered on retryable errors, but the retry is handled by retry_with_backoff.
    # We return a failure-indicating value for the final failure case.
    nil
  end

  # Handles the various HTTP responses from the TMDB API.
  def handle_api_response(response)
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    when Net::HTTPTooManyRequests
      handle_rate_limiting(response)
    else
      PrettyLogger.warn("API request failed for '#{response.uri}': #{response.code} #{response.message}")
      nil
    end
  rescue JSON::ParserError => e
    PrettyLogger.error("Failed to parse JSON response: #{e.message}")
    nil
  end

  # Pauses execution to respect API rate limits.
  def handle_rate_limiting(response)
    retry_after = response['Retry-After']&.to_i || 10
    PrettyLogger.warn("Rate limited by TMDB API. Waiting #{retry_after} seconds...")
    sleep(retry_after)
    raise RateLimitError, "Rate limited: #{response.message}"
  end

  # Builds the full URI for an API request.
  def build_uri(path, params)
    uri = URI("#{TMDB_API_BASE_URL}#{path}")
    uri.query = URI.encode_www_form({ api_key: TMDB_API_KEY }.merge(params))
    uri
  end

  # A generic retry mechanism with exponential backoff.
  def retry_with_backoff(times = 3)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue RateLimitError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, OpenURI::HTTPError => e
      if attempt < times
        sleep_duration = 2 * attempt
        PrettyLogger.debug("Retry attempt #{attempt} after error: #{e.class}. Retrying in #{sleep_duration}s.")
        sleep(sleep_duration)
        retry
      else
        PrettyLogger.error("Request failed after #{times} attempts: #{e.message}")
        raise e # Re-raise the final error
      end
    end
  end
end

# Add blank? helper to String and NilClass for cleaner checks.
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
