# frozen_string_literal: true

require 'spec_helper'
require 'set'

RSpec.describe DatabaseService do
  let(:db) { mock_db_connection }
  let(:service) { described_class.new }
  
  before do
    stub_const('DB', db)
    
    # Setup dataset mocks
    @dataset = double('dataset')
    allow(@dataset).to receive(:where).and_return(@dataset)
    allow(@dataset).to receive(:update).and_return(1)
    allow(@dataset).to receive(:get).and_return(1)
    allow(@dataset).to receive(:select).and_return(@dataset)
    allow(@dataset).to receive(:map).and_return([])
    allow(@dataset).to receive(:to_set).and_return(Set.new)
    
    allow(db).to receive(:[]).and_return(@dataset)
    allow(db).to receive(:synchronize).and_yield(double(put_copy_data: true))
    allow(db).to receive(:fetch).and_return(@dataset)
  end

  describe '#initialize' do
    it 'initializes with database connection' do
      expect(service.conn).to eq(db)
    end

    it 'works without config file' do
      expect { described_class.new(nil) }.not_to raise_error
    end
  end

  describe '#get_existing_file_paths' do
    it 'returns a set of file paths' do
      file_paths = ['/path/1', '/path/2']
      allow(@dataset).to receive(:map).and_return(file_paths)
      allow(file_paths).to receive(:to_set).and_return(Set.new(file_paths))
      
      result = service.get_existing_file_paths
      expect(result).to be_a(Set)
      expect(result.size).to eq(2)
    end

    it 'handles empty results' do
      allow(@dataset).to receive(:map).and_return([])
      result = service.get_existing_file_paths
      expect(result).to be_empty
    end
  end

  describe '#insert_movie' do
    let(:movie_details) { build_movie_details }

    it 'inserts movie with complete data' do
      allow(@dataset).to receive(:get).and_return(123)
      
      movie_id = service.insert_movie(movie_details)
      expect(movie_id).to eq(123)
    end

    it 'handles minimal required data' do
      minimal = { 'id' => 1, 'title' => 'Test' }
      allow(@dataset).to receive(:get).and_return(1)
      
      expect { service.insert_movie(minimal) }.not_to raise_error
    end

    it 'handles conflict with ON CONFLICT DO UPDATE' do
      allow(@dataset).to receive(:get).and_return(456)
      
      movie_id = service.insert_movie(movie_details)
      expect(movie_id).to eq(456)
    end

    it 'handles nil/empty values gracefully' do
      details = movie_details.merge('overview' => nil, 'runtime' => nil)
      allow(@dataset).to receive(:get).and_return(1)
      
      expect { service.insert_movie(details) }.not_to raise_error
    end

    it 'creates franchise if collection exists' do
      expect(service).to receive(:get_or_create_franchise)
        .with(movie_details['belongs_to_collection'])
      service.insert_movie(movie_details)
    end
  end

  describe '#insert_movie_file' do
    let(:mediainfo) do
      double('mediainfo',
        width: 1920,
        height: 1080,
        file_format: 'MKV',
        file_size_mb: 1024,
        video_codec: 'H.264',
        video_bitrate_kbps: 1500,
        frame_rate: 23.976,
        aspect_ratio: '1.78',
        duration_minutes: 120
      )
    end

    it 'inserts file with valid mediainfo' do
      allow(@dataset).to receive(:get).and_return(1)
      
      file_id = service.insert_movie_file(1, '/path/to/movie.mkv', mediainfo)
      expect(file_id).to eq(1)
    end

    it 'handles missing resolution gracefully' do
      allow(mediainfo).to receive(:width).and_return(nil)
      allow(mediainfo).to receive(:height).and_return(nil)
      allow(@dataset).to receive(:get).and_return(1)
      
      expect { service.insert_movie_file(1, '/path/to/movie.mkv', mediainfo) }.not_to raise_error
    end

    it 'handles duplicate file path (returns nil)' do
      allow(@dataset).to receive(:get).and_return(nil)
      
      file_id = service.insert_movie_file(1, '/path/to/movie.mkv', mediainfo)
      expect(file_id).to be_nil
    end

    it 'detects source media type from filename' do
      expect(service).to receive(:guess_source_media_type).with('/path/to/movie.BluRay.mkv')
      service.insert_movie_file(1, '/path/to/movie.BluRay.mkv', mediainfo)
    end
  end

  describe '#bulk_import_associations' do
    let(:movie_details) { build_movie_details }

    it 'imports all associations' do
      expect(service).to receive(:get_or_create_people_bulk).and_return({})
      expect(service).to receive(:link_cast_bulk)
      expect(service).to receive(:link_crew_bulk)
      expect(service).to receive(:get_or_create_generic_bulk).at_least(:once)
      expect(service).to receive(:link_generic_bulk).at_least(:once)
      
      service.bulk_import_associations(1, movie_details)
    end

    it 'handles empty arrays gracefully' do
      empty_details = {
        'credits' => { 'cast' => [], 'crew' => [] },
        'genres' => [],
        'production_countries' => [],
        'spoken_languages' => []
      }
      
      expect { service.bulk_import_associations(1, empty_details) }.not_to raise_error
    end

    it 'handles missing data gracefully' do
      expect { service.bulk_import_associations(1, {}) }.not_to raise_error
    end

    it 'limits cast to first 50 members' do
      large_cast = (1..100).map { |i| { 'id' => i, 'name' => "Actor #{i}" } }
      details = { 'credits' => { 'cast' => large_cast } }
      
      expect(service).to receive(:get_or_create_people_bulk) do |people|
        expect(people.size).to be <= 50
        {}
      end
      
      service.bulk_import_associations(1, details)
    end

    it 'handles duplicate associations' do
      details = movie_details.merge(
        'genres' => [
          { 'name' => 'Action' },
          { 'name' => 'Action' } # duplicate
        ]
      )
      
      expect { service.bulk_import_associations(1, details) }.not_to raise_error
    end
  end

  describe '#update_record' do
    it 'updates record successfully' do
      expect(@dataset).to receive(:where).with(movie_id: 1).and_return(@dataset)
      expect(@dataset).to receive(:update).with(poster_path: 'test.jpg')
      
      service.update_record(
        table: :movies,
        id_col: :movie_id,
        id_val: 1,
        data: { poster_path: 'test.jpg' }
      )
    end

    it 'logs database errors' do
      allow(@dataset).to receive(:where).and_raise(Sequel::DatabaseError.new('Update failed'))
      expect(PrettyLogger).to receive(:error).with(/DB update failed/)
      
      service.update_record(table: :movies, id_col: :movie_id, id_val: 1, data: {})
    end
  end

  describe '#close' do
    it 'disconnects from database' do
      expect(db).to receive(:disconnect)
      service.close
    end

    it 'handles missing disconnect method' do
      allow(db).to receive(:respond_to?).with(:disconnect).and_return(false)
      expect { service.close }.not_to raise_error
    end
  end

  describe 'Bulk Operations' do
    describe '#get_or_create_generic_bulk' do
      it 'creates new items' do
        names = ['Action', 'Drama']
        allow(@dataset).to receive(:map).and_return([1, 2])
        
        ids = service.send(:get_or_create_generic_bulk, 'genres', 'genre_name', 'genre_id', names)
        expect(ids).to eq([1, 2])
      end

      it 'handles existing items' do
        names = ['Action']
        allow(@dataset).to receive(:map).and_return([1])
        
        ids = service.send(:get_or_create_generic_bulk, 'genres', 'genre_name', 'genre_id', names)
        expect(ids).to eq([1])
      end

      it 'returns empty array for empty input' do
        ids = service.send(:get_or_create_generic_bulk, 'genres', 'genre_name', 'genre_id', [])
        expect(ids).to eq([])
      end

      it 'handles mixed new/existing items' do
        names = ['Action', 'NewGenre', 'Drama']
        allow(@dataset).to receive(:map).and_return([1, 2, 3])
        
        ids = service.send(:get_or_create_generic_bulk, 'genres', 'genre_name', 'genre_id', names)
        expect(ids.size).to eq(3)
      end
    end

    describe '#get_or_create_people_bulk' do
      it 'creates people and returns mapping' do
        people = [
          { 'id' => 123, 'name' => 'John Doe' },
          { 'id' => 456, 'name' => 'Jane Smith' }
        ]
        
        result_data = [
          { person_id: 1, tmdb_id: 123 },
          { person_id: 2, tmdb_id: 456 }
        ]
        allow(@dataset).to receive(:each_with_object).and_return(
          { 123 => 1, 456 => 2 }
        )
        
        mapping = service.send(:get_or_create_people_bulk, people)
        expect(mapping).to be_a(Hash)
      end

      it 'handles duplicate TMDB IDs' do
        people = [
          { 'id' => 123, 'name' => 'John Doe' },
          { 'id' => 123, 'name' => 'John Doe Duplicate' }
        ]
        
        allow(@dataset).to receive(:each_with_object).and_return({ 123 => 1 })
        
        mapping = service.send(:get_or_create_people_bulk, people)
        expect(mapping.size).to eq(1)
      end

      it 'returns empty hash for empty input' do
        mapping = service.send(:get_or_create_people_bulk, [])
        expect(mapping).to eq({})
      end
    end

    describe '#link_cast_bulk' do
      let(:cast_data) do
        [
          { 'id' => 123, 'character' => 'Hero', 'order' => 0 },
          { 'id' => 456, 'character' => 'Villain', 'order' => 1 }
        ]
      end
      let(:people_map) { { 123 => 1, 456 => 2 } }

      it 'properly formats COPY data' do
        copy_conn = double('copy_connection')
        expect(copy_conn).to receive(:put_copy_data).twice
        allow(db).to receive(:synchronize).and_yield(copy_conn)
        
        service.send(:link_cast_bulk, 1, cast_data, people_map)
      end

      it 'handles constraint violations' do
        allow(db).to receive(:synchronize).and_raise(PG::UniqueViolation.new)
        expect(PrettyLogger).to receive(:debug)
        
        expect { service.send(:link_cast_bulk, 1, cast_data, people_map) }.not_to raise_error
      end

      it 'skips cast without character' do
        cast_missing_char = [{ 'id' => 123, 'character' => nil, 'order' => 0 }]
        copy_conn = double('copy_connection')
        expect(copy_conn).not_to receive(:put_copy_data)
        allow(db).to receive(:synchronize).and_yield(copy_conn)
        
        service.send(:link_cast_bulk, 1, cast_missing_char, people_map)
      end

      it 'handles empty cast data' do
        expect { service.send(:link_cast_bulk, 1, [], people_map) }.not_to raise_error
      end
    end

    describe '#link_crew_bulk' do
      let(:crew_data) do
        [
          { 'id' => 123, 'job' => 'Director' },
          { 'id' => 456, 'job' => 'Screenplay' },
          { 'id' => 789, 'job' => 'Producer' }
        ]
      end
      let(:people_map) { { 123 => 1, 456 => 2, 789 => 3 } }

      it 'filters directors correctly' do
        expect(service).to receive(:link_generic_bulk).with(
          'movie_directors', 'movie_id', 'person_id', 1, [1]
        )
        expect(service).to receive(:link_generic_bulk).with(
          'movie_writers', 'movie_id', 'person_id', 1, [2]
        )
        
        service.send(:link_crew_bulk, 1, crew_data, people_map)
      end

      it 'handles multiple writers' do
        writers = [
          { 'id' => 1, 'job' => 'Screenplay' },
          { 'id' => 2, 'job' => 'Writer' },
          { 'id' => 3, 'job' => 'Story' }
        ]
        people_map = { 1 => 1, 2 => 2, 3 => 3 }
        
        expect(service).to receive(:link_generic_bulk).with(
          'movie_writers', 'movie_id', 'person_id', 1, [1, 2, 3]
        )
        
        service.send(:link_crew_bulk, 1, writers, people_map)
      end
    end
  end

  describe 'Private Methods' do
    describe '#guess_source_media_type' do
      it 'detects all media type patterns' do
        expect(service.send(:guess_source_media_type, 'Movie.BluRay.mkv')).to eq('Blu-ray')
        expect(service.send(:guess_source_media_type, 'Movie.BLURAY.mkv')).to eq('Blu-ray')
        expect(service.send(:guess_source_media_type, 'Movie.BDREMUX.mkv')).to eq('Blu-ray')
        expect(service.send(:guess_source_media_type, 'Movie.4K.UHD.BluRay.mkv')).to eq('Blu-ray')
        expect(service.send(:guess_source_media_type, 'Movie.DVD.avi')).to eq('DVD')
        expect(service.send(:guess_source_media_type, 'Movie.WEB-DL.mkv')).to eq('Web-DL')
        expect(service.send(:guess_source_media_type, 'Movie.WEBRip.mkv')).to eq('WEB-Rip')
        expect(service.send(:guess_source_media_type, 'Movie.mkv')).to eq('Digital')
      end

      it 'is case insensitive' do
        expect(service.send(:guess_source_media_type, 'movie.bluray.mkv')).to eq('Blu-ray')
        expect(service.send(:guess_source_media_type, 'MOVIE.BLURAY.MKV')).to eq('Blu-ray')
      end

      it 'defaults to Digital for unknown patterns' do
        expect(service.send(:guess_source_media_type, 'random.file.mkv')).to eq('Digital')
        expect(service.send(:guess_source_media_type, '')).to eq('Digital')
      end
    end

    describe '#get_or_create_resolution' do
      it 'creates standard resolutions' do
        allow(@dataset).to receive(:where).and_return(@dataset)
        allow(@dataset).to receive(:get).and_return(nil, 1)
        
        expect(service.send(:get_or_create_resolution, 1920, 1080)).to eq(1)
      end

      it 'returns existing resolution' do
        allow(@dataset).to receive(:where).and_return(@dataset)
        allow(@dataset).to receive(:get).and_return(5)
        
        expect(service.send(:get_or_create_resolution, 1920, 1080)).to eq(5)
      end

      it 'handles custom resolutions' do
        allow(@dataset).to receive(:where).and_return(@dataset)
        allow(@dataset).to receive(:get).and_return(nil, 1)
        
        expect(service.send(:get_or_create_resolution, 1440, 900)).to eq(1)
      end

      it 'returns nil for invalid dimensions' do
        expect(service.send(:get_or_create_resolution, 0, 0)).to be_nil
        expect(service.send(:get_or_create_resolution, -1, 1080)).to be_nil
        expect(service.send(:get_or_create_resolution, nil, nil)).to be_nil
      end

      it 'names resolutions correctly' do
        test_cases = {
          [3840, 2160] => '4K',
          [1920, 1080] => '1080p',
          [1280, 720] => '720p',
          [854, 480] => '480p',
          [1440, 900] => '900p'
        }
        
        test_cases.each do |(width, height), expected_name|
          allow(@dataset).to receive(:where).and_return(@dataset)
          allow(@dataset).to receive(:get).and_return(nil)
          
          expect(db).to receive(:fetch) do |sql, name, w, h|
            expect(name).to eq(expected_name)
            expect(w).to eq(width)
            expect(h).to eq(height)
            @dataset
          end
          
          service.send(:get_or_create_resolution, width, height)
        end
      end
    end

    describe '#get_or_create_generic' do
      it 'returns existing item' do
        allow(@dataset).to receive(:where).and_return(@dataset)
        allow(@dataset).to receive(:get).and_return(5)
        
        id = service.send(:get_or_create_generic, 'genres', 'genre_name', 'genre_id', 'Action')
        expect(id).to eq(5)
      end

      it 'creates new item' do
        allow(@dataset).to receive(:where).and_return(@dataset)
        allow(@dataset).to receive(:get).and_return(nil, 10)
        
        id = service.send(:get_or_create_generic, 'genres', 'genre_name', 'genre_id', 'Action')
        expect(id).to eq(10)
      end

      it 'returns nil for nil or empty name' do
        expect(service.send(:get_or_create_generic, 'genres', 'genre_name', 'genre_id', nil)).to be_nil
        expect(service.send(:get_or_create_generic, 'genres', 'genre_name', 'genre_id', '')).to be_nil
        expect(service.send(:get_or_create_generic, 'genres', 'genre_name', 'genre_id', '   ')).to be_nil
      end
    end

    describe '#get_or_create_franchise' do
      it 'creates franchise from collection data' do
        collection = { 'name' => 'Marvel Cinematic Universe', 'id' => 1 }
        expect(service).to receive(:get_or_create_generic)
          .with('franchises', 'franchise_name', 'franchise_id', 'Marvel Cinematic Universe')
          .and_return(1)
        
        expect(service.send(:get_or_create_franchise, collection)).to eq(1)
      end

      it 'returns nil for missing collection' do
        expect(service.send(:get_or_create_franchise, nil)).to be_nil
        expect(service.send(:get_or_create_franchise, {})).to be_nil
        expect(service.send(:get_or_create_franchise, { 'name' => nil })).to be_nil
      end
    end
  end
end
