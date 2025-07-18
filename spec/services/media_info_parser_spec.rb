# frozen_string_literal: true

require 'spec_helper'
require 'json'

require_relative '../../app/services/media_info_parser'

RSpec.describe MediaInfoParser do
  let(:file_path) { '/path/to/movie.mkv' }
  let(:complete_json) { build_mediainfo_data.to_json }

  before do
    # Mock PrettyLogger to suppress output during tests
    allow(PrettyLogger).to receive(:info)
    allow(PrettyLogger).to receive(:warn)
    allow(PrettyLogger).to receive(:error)
    allow(PrettyLogger).to receive(:debug)
  end

  # Helper to create a parser instance with specific command output and status
  def create_parser(output, success: true)
    # Stub the backtick command execution
    allow(Kernel).to receive(:`).with(/mediainfo/).and_return(output)
    # Stub the exit status of the command
    allow(Process).to receive(:last_status).and_return(instance_double(Process::Status, success?: success))
    MediaInfoParser.new(file_path)
  end

  describe '#initialize' do
    context 'with successful mediainfo execution' do
      let(:parser) { create_parser(complete_json, success: true) }

      it 'parses JSON output and is valid' do
        expect(parser).to be_valid
      end

      it 'extracts all properties correctly' do
        expect(parser.width).to eq(3840)
        expect(parser.height).to eq(2160)
        expect(parser.file_format).to eq('Matroska')
        expect(parser.duration_minutes).to eq(120)
        expect(parser.file_size_mb).to eq(1024)
        expect(parser.video_codec).to eq('H.265')
        expect(parser.video_bitrate_kbps).to eq(1500)
        expect(parser.frame_rate).to eq(23.976)
        expect(parser.aspect_ratio).to eq('2.39')
      end
    end

    context 'when mediainfo command fails' do
      let(:parser) { create_parser('error output', success: false) }

      it 'is invalid' do
        expect(parser).not_to be_valid
      end

      it 'has nil data' do
        expect(parser.instance_variable_get(:@data)).to be_nil
      end
    end

    context 'when mediainfo command is not found' do
      it 'is invalid and logs an error' do
        allow(Kernel).to receive(:`).with(/mediainfo/).and_raise(Errno::ENOENT)
        parser = MediaInfoParser.new(file_path)
        expect(parser).not_to be_valid
        expect(PrettyLogger).to have_received(:error).with(/`mediainfo` command not found/)
      end
    end

    context 'with invalid JSON output' do
      let(:parser) { create_parser('invalid json', success: true) }

      it 'handles parse errors gracefully and is invalid' do
        expect(parser).not_to be_valid
        expect(PrettyLogger).to have_received(:warn).with(/Failed to parse mediainfo JSON/)
      end
    end
  end

  describe '#valid?' do
    it 'returns true when media data is valid' do
      parser = create_parser(complete_json, success: true)
      expect(parser).to be_valid
    end

    it 'returns false when media data is nil' do
      parser = create_parser('{}', success: true)
      expect(parser).not_to be_valid
    end
  end

  describe 'parsing various mediainfo outputs' do
    context 'with missing video track' do
      it 'handles gracefully with nil values' do
        data = build_mediainfo_data
        data['media']['track'].delete_if { |t| t['@type'] == 'Video' }
        parser = create_parser(data.to_json, success: true)

        expect(parser.width).to be_nil
        expect(parser.video_codec).to be_nil
      end
    end

    context 'with multiple video tracks' do
      it 'uses the first video track' do
        data = build_mediainfo_data
        data['media']['track'] << { '@type' => 'Video', 'Width' => '1280' }
        parser = create_parser(data.to_json, success: true)

        expect(parser.width).to eq(3840)
      end
    end
  end

  describe 'private methods' do
    describe '#normalize_aspect_ratio' do
      let(:parser) { create_parser(complete_json, success: true) }
      let(:mappings) do
        {
          '1.33:1' => '1.33', '4:3' => '1.33', '1.78:1' => '1.78', '16:9' => '1.78',
          '1.85:1' => '1.85', '2.35:1' => '2.35', '2.39:1' => '2.39', '2.40:1' => '2.39'
        }
      end

      it 'maps all expected ratios correctly' do
        mappings.each do |input, expected|
          expect(parser.send(:normalize_aspect_ratio, input)).to eq(expected)
        end
      end

      it 'returns nil for unmapped or invalid ratios' do
        expect(parser.send(:normalize_aspect_ratio, '1.5:1')).to be_nil
        expect(parser.send(:normalize_aspect_ratio, nil)).to be_nil
      end
    end
  end
end

def build_mediainfo_data
  {
    'media' => {
      'track' => [
        {
          '@type' => 'General',
          'Format' => 'Matroska',
          'FileSize' => '1073741824', # 1 GB
          'Duration' => '7200'        # 120 minutes
        },
        {
          '@type' => 'Video',
          'Width' => '3840',
          'Height' => '2160',
          'Format' => 'H.265',
          'BitRate' => '1500000',     # 1500 kbps
          'FrameRate' => '23.976',
          'DisplayAspectRatio' => '2.39:1'
        }
      ]
    }
  }
end