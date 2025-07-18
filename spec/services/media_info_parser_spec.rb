# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe MediaInfoParser do
  let(:complete_json) { build_mediainfo_data.to_json }
  let(:parser) { described_class.new('/path/to/movie.mkv') }

  before do
    allow(parser).to receive(:`).with(/mediainfo --Output=JSON/).and_return(complete_json)
    allow($CHILD_STATUS).to receive(:success?).and_return(true)
  end

  describe '#initialize' do
    context 'with successful mediainfo execution' do
      it 'parses JSON output' do
        expect(parser).to be_valid
      end

      it 'extracts all properties' do
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

    context 'with mediainfo command failure' do
      before do
        allow($CHILD_STATUS).to receive(:success?).and_return(false)
      end

      it 'is invalid' do
        expect(parser).not_to be_valid
      end

      it 'sets data to nil' do
        expect(parser.instance_variable_get(:@data)).to be_nil
      end
    end

    context 'with invalid JSON output' do
      before do
        allow(parser).to receive(:`).and_return('invalid json')
      end

      it 'handles parse errors gracefully' do
        expect { parser }.not_to raise_error
        expect(parser).not_to be_valid
      end
    end
  end

  describe '#valid?' do
    it 'returns true when media data exists' do
      expect(parser).to be_valid
    end

    it 'returns false when media data is nil' do
      allow(parser).to receive(:`).and_return('{}')
      expect(parser).not_to be_valid
    end
  end

  describe 'parsing various mediainfo outputs' do
    context 'with complete media info' do
      it 'parses all fields correctly' do
        expect(parser.file_format).to eq('Matroska')
        expect(parser.duration_minutes).to eq(120)
        expect(parser.file_size_mb).to eq(1024)
        expect(parser.video_codec).to eq('H.265')
        expect(parser.video_bitrate_kbps).to eq(1500)
        expect(parser.frame_rate).to eq(23.976)
        expect(parser.aspect_ratio).to eq('2.39')
        expect(parser.width).to eq(3840)
        expect(parser.height).to eq(2160)
      end
    end

    context 'with missing video track' do
      let(:json_no_video) do
        {
          'media' => {
            'track' => [
              { '@type' => 'General', 'Format' => 'Matroska' }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(json_no_video)
      end

      it 'handles gracefully' do
        expect(parser.width).to be_nil
        expect(parser.height).to be_nil
        expect(parser.video_codec).to be_nil
      end
    end

    context 'with missing general track' do
      let(:json_no_general) do
        {
          'media' => {
            'track' => [
              { '@type' => 'Video', 'Width' => '1920' }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(json_no_general)
      end

      it 'handles gracefully' do
        expect(parser.file_format).to be_nil
        expect(parser.duration_minutes).to be_nil
        expect(parser.file_size_mb).to be_nil
      end
    end

    context 'with multiple video tracks' do
      let(:json_multiple_video) do
        {
          'media' => {
            'track' => [
              { '@type' => 'General' },
              { '@type' => 'Video', 'Width' => '1920', 'Height' => '1080' },
              { '@type' => 'Video', 'Width' => '1280', 'Height' => '720' }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(json_multiple_video)
      end

      it 'uses first video track' do
        expect(parser.width).to eq(1920)
        expect(parser.height).to eq(1080)
      end
    end

    context 'with unusual aspect ratios' do
      test_cases = {
        '2.00:1' => '2.00',
        '2.20:1' => '2.20',
        '1.85:1' => '1.85',
        '2.76:1' => nil, # Not in mapping
        '3.5:1' => nil   # Unusual ratio
      }

      test_cases.each do |input, expected|
        it "normalizes #{input} to #{expected.inspect}" do
          expect(parser.send(:normalize_aspect_ratio, input)).to eq(expected)
        end
      end
    end

    context 'with HDR metadata' do
      let(:json_with_hdr) do
        {
          'media' => {
            'track' => [
              { '@type' => 'General' },
              {
                '@type' => 'Video',
                'Width' => '3840',
                'Height' => '2160',
                'HDR_Format' => 'Dolby Vision',
                'ColorSpace' => 'BT.2020'
              }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(json_with_hdr)
      end

      it 'extracts standard properties' do
        expect(parser.width).to eq(3840)
        expect(parser.height).to eq(2160)
      end
    end
  end

  describe 'error handling' do
    context 'when mediainfo command fails' do
      before do
        allow(parser).to receive(:`).and_raise(Errno::ENOENT.new('mediainfo'))
      end

      it 'handles command not found' do
        expect { parser }.not_to raise_error
        expect(parser).not_to be_valid
      end
    end

    context 'with timeout' do
      before do
        allow(parser).to receive(:`).and_raise(Timeout::Error)
      end

      it 'handles timeout gracefully' do
        expect { parser }.not_to raise_error
        expect(parser).not_to be_valid
      end
    end

    context 'with malformed JSON' do
      before do
        allow(parser).to receive(:`).and_return('{"invalid": json"}')
      end

      it 'handles parse errors' do
        expect(parser).not_to be_valid
      end
    end
  end

  describe 'private methods' do
    describe '#parse' do
      it 'calculates duration in minutes' do
        expect(parser.duration_minutes).to eq(120) # 7200 seconds / 60
      end

      it 'calculates file size in MB' do
        expect(parser.file_size_mb).to eq(1024) # 1073741824 bytes / 1024 / 1024
      end

      it 'calculates video bitrate in kbps' do
        expect(parser.video_bitrate_kbps).to eq(1500) # 1500000 bps / 1000
      end

      it 'rounds frame rate to 3 decimal places' do
        expect(parser.frame_rate).to eq(23.976)
      end

      it 'handles missing fields gracefully' do
        json = {
          'media' => {
            'track' => [
              { '@type' => 'General' },
              { '@type' => 'Video' }
            ]
          }
        }.to_json
        
        allow(parser).to receive(:`).and_return(json)
        
        expect(parser.duration_minutes).to be_nil
        expect(parser.file_size_mb).to be_nil
      end
    end

    describe '#track' do
      it 'finds track by type' do
        general = parser.send(:track, 'General')
        expect(general).to be_a(Hash)
        expect(general['@type']).to eq('General')
      end

      it 'returns nil for non-existent track type' do
        audio = parser.send(:track, 'Subtitle')
        expect(audio).to be_nil
      end
    end

    describe '#normalize_aspect_ratio' do
      let(:mappings) do
        {
          '1.33:1' => '1.33',
          '4:3' => '1.33',
          '1.37:1' => '1.33',
          '1.66:1' => '1.66',
          '1.78:1' => '1.78',
          '16:9' => '1.78',
          '1.85:1' => '1.85',
          '2.00:1' => '2.00',
          '2.20:1' => '2.20',
          '2.35:1' => '2.35',
          '2.39:1' => '2.39',
          '2.40:1' => '2.39'
        }
      end

      it 'maps all expected ratios correctly' do
        mappings.each do |input, expected|
          result = parser.send(:normalize_aspect_ratio, input)
          expect(result).to eq(expected), "Expected #{input} to map to #{expected}"
        end
      end

      it 'returns nil for unmapped ratios' do
        expect(parser.send(:normalize_aspect_ratio, '1.5:1')).to be_nil
        expect(parser.send(:normalize_aspect_ratio, 'invalid')).to be_nil
        expect(parser.send(:normalize_aspect_ratio, nil)).to be_nil
      end
    end
  end

  describe 'integration with real mediainfo output formats' do
    context 'with MKV file' do
      let(:mkv_json) do
        {
          'media' => {
            'track' => [
              {
                '@type' => 'General',
                'Format' => 'Matroska',
                'Format_Version' => '4',
                'Duration' => '6853.120',
                'FileSize' => '8539029504'
              },
              {
                '@type' => 'Video',
                'Format' => 'HEVC',
                'BitRate' => '8951235',
                'Width' => '3840',
                'Height' => '1608',
                'FrameRate' => '23.976',
                'DisplayAspectRatio' => '2.39:1'
              }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(mkv_json)
      end

      it 'parses MKV properties correctly' do
        expect(parser.file_format).to eq('Matroska')
        expect(parser.video_codec).to eq('HEVC')
        expect(parser.duration_minutes).to eq(114) # 6853 seconds
        expect(parser.file_size_mb).to eq(8144) # 8539029504 bytes
      end
    end

    context 'with MP4 file' do
      let(:mp4_json) do
        {
          'media' => {
            'track' => [
              {
                '@type' => 'General',
                'Format' => 'MPEG-4',
                'Duration' => '5428.261',
                'FileSize' => '2147483648'
              },
              {
                '@type' => 'Video',
                'Format' => 'AVC',
                'BitRate' => '2976435',
                'Width' => '1920',
                'Height' => '1080',
                'FrameRate' => '29.970',
                'DisplayAspectRatio' => '16:9'
              }
            ]
          }
        }.to_json
      end

      before do
        allow(parser).to receive(:`).and_return(mp4_json)
      end

      it 'parses MP4 properties correctly' do
        expect(parser.file_format).to eq('MPEG-4')
        expect(parser.video_codec).to eq('AVC')
        expect(parser.aspect_ratio).to eq('1.78')
        expect(parser.frame_rate).to eq(29.970)
      end
    end
  end
end
