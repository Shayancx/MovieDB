require 'json'

class MediaInfoParser
  attr_reader :width, :height, :file_format, :duration_minutes,
              :file_size_mb, :video_codec, :video_bitrate_kbps,
              :frame_rate, :aspect_ratio

  def initialize(file_path)
    json_output = `mediainfo --Output=JSON -f "#{file_path}"`
    @data = $?.success? ? JSON.parse(json_output) : nil
    @media = @data ? @data['media'] : nil
    parse
  end

  def valid?
    !@media.nil?
  end

  private

  def parse
    return unless valid?
    general = track('General')
    video = track('Video')
    return unless general && video
    @file_format = general['Format']
    @duration_minutes = (general['Duration'].to_f / 60).round
    @file_size_mb = (general['FileSize'].to_f / 1024 / 1024).round
    @video_codec = video['Format']
    @video_bitrate_kbps = (video['BitRate'].to_f / 1000).round
    @frame_rate = video['FrameRate'].to_f.round(3)
    @aspect_ratio = normalize_aspect_ratio(video['DisplayAspectRatio'])
    @width = video['Width'].to_i
    @height = video['Height'].to_i
  end

  def track(type)
    (@media['track'] || []).find { |t| t['@type'] == type }
  end

  def normalize_aspect_ratio(ratio_str)
    {
      '1.33:1' => '1.33', '4:3' => '1.33', '1.37:1' => '1.33', '1.66:1' => '1.66',
      '1.78:1' => '1.78', '16:9' => '1.78', '1.85:1' => '1.85', '2.00:1' => '2.00',
      '2.20:1' => '2.20', '2.35:1' => '2.35', '2.39:1' => '2.39', '2.40:1' => '2.39'
    }[ratio_str]
  end
end
