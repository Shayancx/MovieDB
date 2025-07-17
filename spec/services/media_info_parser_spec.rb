require 'spec_helper'

RSpec.describe 'MediaInfoParser' do
  before do
    load File.expand_path('../../../app/services/media_info_parser.rb', __FILE__)
  end

  let(:json_output) do
    {
      'media' => {
        'track' => [
          {
            '@type' => 'General',
            'Format' => 'Matroska',
            'Duration' => '1200',
            'FileSize' => '104857600'
          },
          {
            '@type' => 'Video',
            'Format' => 'H.264',
            'BitRate' => '800000',
            'FrameRate' => '23.976',
            'DisplayAspectRatio' => '16:9',
            'Width' => '1920',
            'Height' => '1080'
          }
        ]
      }
    }.to_json
  end

  it 'parses mediainfo data' do
    parser = MediaInfoParser.allocate
    media = JSON.parse(json_output)['media']
    parser.instance_variable_set(:@media, media)
    parser.send(:parse)
    expect(parser).to be_valid
    expect(parser.width).to eq(1920)
    expect(parser.height).to eq(1080)
    expect(parser.video_codec).to eq('H.264')
    expect(parser.aspect_ratio).to eq('1.78')
  end

  it 'is invalid when media missing' do
    parser = MediaInfoParser.allocate
    parser.instance_variable_set(:@media, nil)
    parser.send(:parse)
    expect(parser).not_to be_valid
  end
end
