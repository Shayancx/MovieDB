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

  def get_movie_details(tmdb_id)
    make_api_request("/movie/#{tmdb_id}", append_to_response: 'credits,release_dates,images')
  end

  def download_image(api_path, relative_save_path)
    return nil if api_path.nil? || api_path.empty?
    source_url = "#{TMDB_IMAGE_BASE_URL}#{api_path}"
    absolute_save_path = File.join(MEDIA_BASE_DIR, relative_save_path)
    return relative_save_path if File.exist?(absolute_save_path)
    FileUtils.mkdir_p(File.dirname(absolute_save_path))
    retry_with_backoff do
      URI.open(source_url) do |image|
        File.open(absolute_save_path, 'wb') { |file| file.write(image.read) }
      end
    end
    PrettyLogger.debug("Downloaded image to #{relative_save_path}")
    relative_save_path
  rescue => e
    PrettyLogger.warn("Failed to download image from #{source_url}: #{e.message}")
    nil
  end

  private

  def make_api_request(path, params = {}, retries = 3)
    params[:api_key] = TMDB_API_KEY
    uri = URI("#{TMDB_API_BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)
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
      PrettyLogger.warn("API request failed for '#{path}': #{response.code} #{response.message}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
    if retries > 0
      PrettyLogger.warn("Network error (#{e.class}). Retrying in #{5 - retries}s...")
      sleep(5 - retries)
      make_api_request(path, params, retries - 1)
    else
      PrettyLogger.error("API request failed after multiple retries for '#{path}': #{e.message}")
      nil
    end
  end

  def retry_with_backoff(times = 3)
    yield
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, OpenURI::HTTPError => e
    if (times -= 1) > 0
      sleep(3 - times)
      retry
    else
      raise e
    end
  end
end
