# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'open-uri'
require 'fileutils'
require_relative 'pretty_logger'
require_relative 'import_config'

class TmdbClient
  include ImportConfig

  def initialize
    uri = URI(TMDB_API_BASE_URL)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    @http.open_timeout = 10
    @http.read_timeout = 30
  end

  def search_movie(name, year)
    response = make_api_request('/search/movie', { query: name, year: year }.compact)
    (response && response['results']) || []
  end

  def search_series(name, year)
    response = make_api_request('/search/tv', { query: name, first_air_date_year: year }.compact)
    (response && response['results']) || []
  end

  def get_movie_details(tmdb_id)
    make_api_request("/movie/#{tmdb_id}", append_to_response: 'credits,release_dates,images')
  end

  def get_series_details(tmdb_id)
    make_api_request("/tv/#{tmdb_id}", append_to_response: 'aggregate_credits,images,external_ids')
  end

  def get_season_details(tmdb_id, season_number)
    make_api_request("/tv/#{tmdb_id}/season/#{season_number}")
  end

  def download_image(api_path, relative_save_path)
    return nil if api_path.nil? || api_path.empty?

    source_url = "#{TMDB_IMAGE_BASE_URL}#{api_path}"
    absolute_save_path = File.join(MEDIA_BASE_DIR, relative_save_path)
    
    # Check if file already exists
    if File.exist?(absolute_save_path)
      PrettyLogger.debug("Image already exists: #{relative_save_path}")
      return relative_save_path
    end

    PrettyLogger.info("Downloading image: #{api_path} -> #{relative_save_path}")
    
    # Ensure directory exists
    FileUtils.mkdir_p(File.dirname(absolute_save_path))
    
    # Check directory is writable
    unless File.writable?(File.dirname(absolute_save_path))
      PrettyLogger.error("Directory not writable: #{File.dirname(absolute_save_path)}")
      return nil
    end
    
    retry_with_backoff do
      URI.open(source_url) do |image|
        File.open(absolute_save_path, 'wb') do |file|
          file.write(image.read)
        end
      end
    end
    
    PrettyLogger.success("Downloaded image to #{relative_save_path}")
    relative_save_path
  rescue StandardError => e
    PrettyLogger.error("Failed to download image from #{source_url}: #{e.message}")
    PrettyLogger.debug(e.backtrace.join("\n")) if ENV['DEBUG']
    nil
  end

  private

  def make_api_request(path, params = {}, retries = 3)
    params[:api_key] = TMDB_API_KEY
    uri = URI("#{TMDB_API_BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)
    
    PrettyLogger.debug("API Request: #{uri}")
    
    request = Net::HTTP::Get.new(uri)
    response = @http.request(request)
    
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    when Net::HTTPTooManyRequests
      retry_after = response['Retry-After']&.to_i || 10
      PrettyLogger.warn("Rate limited by TMDB API. Waiting #{retry_after} seconds...")
      sleep(retry_after)
      make_api_request(path, params)
    else
      PrettyLogger.error("API request failed for '#{path}': #{response.code} #{response.message}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
    if retries.positive?
      PrettyLogger.warn("Network error (#{e.class}). Retrying in #{5 - retries}s...")
      sleep(5 - retries)
      make_api_request(path, params, retries - 1)
    else
      PrettyLogger.error("API request failed after multiple retries for '#{path}': #{e.message}")
      nil
    end
  end

  def retry_with_backoff(times = 3)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, OpenURI::HTTPError => e
      if attempt < times
        PrettyLogger.debug("Retry attempt #{attempt} after error: #{e.message}")
        sleep(attempt)
        retry
      else
        raise e
      end
    end
  end
end
