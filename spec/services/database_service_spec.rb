require 'spec_helper'

RSpec.describe 'DatabaseService' do
  before do
    db = Class.new do
      def extension(*) = nil
      def test_connection = nil
    end.new
    allow(Sequel).to receive(:connect).and_return(db)
    load File.expand_path('../../../app/services/database_service.rb', __FILE__)
    stub_const('DB', db)
  end

  subject(:service) { DatabaseService.new }

  describe '#guess_source_media_type' do
    it 'detects Blu-ray related names' do
      expect(service.send(:guess_source_media_type, 'Movie.Bluray.mkv')).to eq('Blu-ray')
      expect(service.send(:guess_source_media_type, 'Movie.BDREMUX.mkv')).to eq('Blu-ray')
    end

    it 'detects 4K Blu-ray names' do
      expect(service.send(:guess_source_media_type, 'Movie.4K.UHD.BluRay.mkv')).to eq('Blu-ray')
    end

    it 'detects DVD names' do
      expect(service.send(:guess_source_media_type, 'Movie.DVD.avi')).to eq('DVD')
    end

    it 'defaults to Digital' do
      expect(service.send(:guess_source_media_type, 'Movie.WEBRip.mkv')).to eq('WEB-Rip')
      expect(service.send(:guess_source_media_type, 'Movie.unknown.mkv')).to eq('Digital')
    end
  end
end
