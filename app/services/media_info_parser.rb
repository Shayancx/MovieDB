# frozen_string_literal: true

require 'json'
require_relative 'pretty_logger'

# Parses media file metadata using the 'mediainfo' command-line tool.
class MediaInfoParser
  attr_reader :width, :height, :file_format, :duration_minutes,
              :file_size_mb, :video_codec, :video_bitrate_kbps,
              :frame_rate, :aspect_ratio

  # Initializes the parser by executing the mediainfo command and parsing its JSON output.
  def initialize(file_path)
    @data = execute_mediainfo(file_path)
    @media = @data&.dig('media')
    parse if valid?
  end

  # Returns true if the mediainfo data was successfully parsed.
  def valid?
    !@media.nil?
  end

  private

  # Executes the mediainfo command and returns the parsed JSON data.
  def execute_mediainfo(file_path)
    # Use Kernel.` to allow for easier stubbing in tests.
    json_output = Kernel.`("mediainfo --Output=JSON -f \"#{file_path}\" 2>/dev/null")

    # Check the exit status of the last command.
    unless Process.last_status.success?
      PrettyLogger.warn("mediainfo command failed for: #{File.basename(file_path)}")
      return nil
    end

    JSON.parse(json_output)
  rescue JSON::ParserError => e
    PrettyLogger.warn("Failed to parse mediainfo JSON output for #{File.basename(file_path)}: #{e.message}")
    nil
  rescue Errno::ENOENT
    PrettyLogger.error("`mediainfo` command not found. Please install it and ensure it's in your PATH.")
    nil
  end

  # Parses the raw data from @media into instance variables.
  def parse
    general = track('General')
    video = track('Video')
    return unless general && video

    @file_format = general['Format']
    @duration_minutes = (general['Duration'].to_f / 60).round if general['Duration']
    @file_size_mb = (general['FileSize'].to_f / (1024 * 1024)).round if general['FileSize']
    @video_codec = video['Format']
    @video_bitrate_kbps = (video['BitRate'].to_f / 1000).round if video['BitRate']
    @frame_rate = video['FrameRate']&.to_f&.round(3)
    @aspect_ratio = normalize_aspect_ratio(video['DisplayAspectRatio'])
    @width = video['Width']&.to_i
    @height = video['Height']&.to_i
  end

  # Finds a specific track type (e.g., 'General', 'Video') from the media data.
  def track(type)
    (@media['track'] || []).find { |t| t['@type'] == type }
  end

  # Normalizes various aspect ratio strings to a standard format.
  def normalize_aspect_ratio(ratio_str)
    return nil unless ratio_str.is_a?(String)

    # Mapping of common aspect ratios to a standard string representation.
    @aspect_ratio_map ||= {
      '1.33:1' => '1.33', '4:3' => '1.33', '1.37:1' => '1.33', '1.66:1' => '1.66',
      '1.78:1' => '1.78', '16:9' => '1.78', '1.85:1' => '1.85', '2.00:1' => '2.00',
      '2.20:1' => '2.20', '2.35:1' => '2.35', '2.39:1' => '2.39', '2.40:1' => '2.39'
    }
    @aspect_ratio_map[ratio_str]
  end
end