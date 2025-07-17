require 'spec_helper'

RSpec.describe 'TMDBMovieImporter' do
  before do
    load File.expand_path('../../../app/services/tmdb_movie_importer.rb', __FILE__)
  end

  let(:importer) { TMDBMovieImporter.allocate }

  describe '#parse_filename' do
    it 'parses name, year and tmdb id from filename with id' do
      result = importer.send(:parse_filename, 'Inception (2010) (tmdbid-123).mkv')
      expect(result).to eq(name: 'Inception', year: 2010, tmdb_id: 123)
    end

    it 'parses name and year from filename without id' do
      result = importer.send(:parse_filename, 'The.Matrix.1999 (1999).mp4')
      expect(result).to eq(name: 'The Matrix 1999', year: 1999)
    end

    it 'returns nil for unrecognized filename' do
      expect(importer.send(:parse_filename, 'randomfile.mkv')).to be_nil
    end
  end

  describe '#find_best_image' do
    it 'prefers exact language match then English then no language' do
      images = [
        { 'file_path' => '/a.jpg', 'iso_639_1' => 'fr' },
        { 'file_path' => '/b.jpg', 'iso_639_1' => 'en' },
        { 'file_path' => '/c.jpg', 'iso_639_1' => nil }
      ]
      expect(importer.send(:find_best_image, images, 'fr')).to eq(images[0])
      expect(importer.send(:find_best_image, images, 'de')).to eq(images[1])
      expect(importer.send(:find_best_image, images[2..2], 'de')).to eq(images[2])
    end
  end
end
