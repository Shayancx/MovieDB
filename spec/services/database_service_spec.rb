# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/database_service'

RSpec.describe DatabaseService do
  let(:db) { mock_db_connection }
  let(:service) { described_class.new }
  let(:movie_details) { build_movie_details_for_db }
  let(:mock_table) { double('mock_table') }

  before do
    # Stub the main DB connection and default table responses
    stub_const('DB', db)
    allow(db).to receive(:[]).and_return(mock_table)
    allow(mock_table).to receive(:insert_conflict).and_return(mock_table)
    allow(mock_table).to receive(:insert_ignore).and_return(mock_table)
    allow(mock_table).to receive(:multi_insert)
    allow(mock_table).to receive(:insert)
    allow(mock_table).to receive(:where).and_return(mock_table)
    allow(mock_table).to receive(:get)
    allow(mock_table).to receive(:select_map).and_return([])

    allow(PrettyLogger).to receive(:error)
  end

  describe '#insert_movie' do
    it 'inserts a movie and returns its ID' do
      allow(service).to receive(:get_or_create_franchise).and_return(1)
      allow(mock_table).to receive(:get).with(:movie_id).and_return(123)
      expect(service.insert_movie(movie_details)).to eq(123)
    end
  end

  describe '#insert_movie_file' do
    let(:mediainfo) { instance_double(MediaInfoParser, width: 1920, height: 1080, file_format: 'MKV', video_codec: 'H.264', file_size_mb: 2000, duration_minutes: 120, frame_rate: 23.976, aspect_ratio: '16:9', video_bitrate_kbps: 8000) }

    it 'inserts a movie file record and returns its ID' do
      allow(service).to receive(:get_or_create_generic).and_return(1, 2)
      allow(service).to receive(:get_or_create_resolution).and_return(3)
      allow(mock_table).to receive(:get).with(:file_id).and_return(456)

      file_id = service.insert_movie_file(1, '/path/to/movie.mkv', mediainfo)
      expect(file_id).to eq(456)
    end
  end

  describe '#bulk_import_associations' do
    it 'calls all link methods' do
      allow(service).to receive(:get_or_create_people_bulk).and_return({})
      expect(service).to receive(:link_cast_bulk)
      expect(service).to receive(:link_crew_bulk)
      expect(service).to receive(:link_genres_bulk)
      expect(service).to receive(:link_countries_bulk)
      expect(service).to receive(:link_languages_bulk)
      service.bulk_import_associations(1, movie_details)
    end
  end

  describe '#update_record' do
    it 'updates a record in the specified table' do
      allow(mock_table).to receive(:update)
      service.update_record(:movies, 1, { rating: 9.9 })
      expect(mock_table).to have_received(:update).with({ rating: 9.9 })
    end

    it 'logs an error on database failure' do
      allow(mock_table).to receive(:update).and_raise(Sequel::DatabaseError)
      service.update_record(:movies, 1, { rating: 9.9 })
      expect(PrettyLogger).to have_received(:error)
    end
  end

  describe 'private methods' do
    describe '#get_or_create_people_bulk' do
      it 'returns a map of TMDB IDs to database IDs' do
        allow(mock_table).to receive(:select_map).with([:tmdb_person_id, :person_id]).and_return([[100, 1]])
        people_map = service.send(:get_or_create_people_bulk, movie_details)
        expect(people_map).to eq({ 100 => 1 })
      end
    end

    describe '#link_generic_bulk' do
      it 'inserts multiple records into a join table' do
        expect(mock_table).to receive(:multi_insert)
        service.send(:link_generic_bulk, :movie_genres, :movie_id, :genre_id, 1, [1, 2, 3])
      end
    end

    describe '#get_or_create_generic_bulk' do
      it 'returns an array of IDs for the given names' do
        allow(mock_table).to receive(:select_map).with(:genre_id).and_return([1, 2])
        ids = service.send(:get_or_create_generic_bulk, :genres, :genre_name, ['Action', 'Adventure'])
        expect(ids).to eq([1, 2])
      end
    end
  end
end

def build_movie_details_for_db
  {
    'id' => 123,
    'tmdb_id' => 123,
    'title' => 'Test Movie',
    'original_title' => 'Test Movie Original',
    'release_date' => '2023-01-01',
    'overview' => 'An exciting test movie.',
    'runtime' => 120,
    'imdb_id' => 'tt1234567',
    'vote_average' => 8.5,
    'belongs_to_collection' => { 'name' => 'Test Collection' },
    'genres' => [{ 'name' => 'Action' }, { 'name' => 'Adventure' }],
    'production_countries' => [{ 'name' => 'United States' }],
    'spoken_languages' => [{ 'english_name' => 'English' }],
    'credits' => {
      'cast' => [{ 'id' => 100, 'name' => 'Actor 1', 'character' => 'Hero', 'order' => 1 }],
      'crew' => [
        { 'id' => 200, 'name' => 'Director 1', 'job' => 'Director' },
        { 'id' => 300, 'name' => 'Writer 1', 'job' => 'Writer' }
      ]
    }
  }
end