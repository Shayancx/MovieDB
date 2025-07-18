# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MovieService do
  let(:db) { mock_db_connection }
  
  before do
    stub_const('DB', db)
    
    # Setup fetch mock
    fetch_result = double('fetch_result')
    allow(fetch_result).to receive(:all).and_return([])
    allow(fetch_result).to receive(:first).and_return(nil)
    allow(db).to receive(:fetch).and_return(fetch_result)
    
    # Setup dataset mocks
    @dataset = double('dataset')
    allow(@dataset).to receive(:order).and_return(@dataset)
    allow(@dataset).to receive(:all).and_return([])
    allow(@dataset).to receive(:exclude).and_return(@dataset)
    allow(@dataset).to receive(:select).and_return(@dataset)
    allow(@dataset).to receive(:distinct).and_return(@dataset)
    allow(@dataset).to receive(:map).and_return([])
    allow(@dataset).to receive(:join).and_return(@dataset)
    allow(@dataset).to receive(:left_join).and_return(@dataset)
    allow(@dataset).to receive(:where).and_return(@dataset)
    allow(@dataset).to receive(:select_map).and_return([])
    
    allow(db).to receive(:[]).and_return(@dataset)
    
    # Mock Sequel functions
    allow(Sequel).to receive(:function).and_return(double(as: :year))
    allow(Sequel).to receive(:desc).and_return(:desc)
  end

  describe '.list' do
    it 'returns all movies with associations' do
      movies = [
        { movie_id: 1, movie_name: 'Test Movie', genres: ['Action'], countries: ['USA'] }
      ]
      allow(db).to receive(:fetch).and_return(double(all: movies))
      
      result = described_class.list
      expect(result).to eq(movies)
    end

    it 'handles empty database' do
      allow(db).to receive(:fetch).and_return(double(all: []))
      
      result = described_class.list
      expect(result).to eq([])
    end

    it 'includes all joined data' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: [])
      end
      
      described_class.list
      expect(sql).to include('LEFT JOIN franchises')
      expect(sql).to include('LEFT JOIN movie_genres')
      expect(sql).to include('LEFT JOIN genres')
      expect(sql).to include('LEFT JOIN movie_countries')
      expect(sql).to include('LEFT JOIN countries')
      expect(sql).to include('LEFT JOIN movie_languages')
      expect(sql).to include('LEFT JOIN languages')
    end
  end

  describe '.filtered' do
    let(:filters) { {} }
    let(:movies) { [{ movie_id: 1, movie_name: 'Test' }] }
    
    before do
      allow(db).to receive(:fetch).and_return(double(all: movies))
    end

    it 'applies search filter with case insensitive partial match' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(search: 'inception')
      expect(sql_args).to eq(['%inception%', '%inception%'])
    end

    it 'applies genre filter' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(genre: 'Action')
      expect(sql_args).to include('Action')
    end

    it 'applies country filter' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(country: 'USA')
      expect(sql_args).to include('USA')
    end

    it 'applies language filter' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(language: 'English')
      expect(sql_args).to include('English')
    end

    it 'applies franchise filter' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(franchise: '1')
      expect(sql_args).to include('1')
    end

    it 'applies year filter' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(year: '2023')
      expect(sql_args).to include(2023)
    end

    it 'combines multiple filters' do
      sql_args = []
      allow(db).to receive(:fetch) do |sql, *args|
        sql_args = args
        double(all: movies)
      end
      
      described_class.filtered(
        search: 'test',
        genre: 'Action',
        country: 'USA',
        year: '2023'
      )
      expect(sql_args).to eq(['%test%', '%test%', 'Action', 'USA', 2023])
    end

    it 'applies sorting by name (default)' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_by: 'name')
      expect(sql).to include('ORDER BY m.movie_name')
    end

    it 'applies sorting by date' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_by: 'date')
      expect(sql).to include('ORDER BY m.release_date')
    end

    it 'applies sorting by rating' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_by: 'rating')
      expect(sql).to include('ORDER BY m.rating')
    end

    it 'applies sorting by runtime' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_by: 'runtime')
      expect(sql).to include('ORDER BY m.runtime_minutes')
    end

    it 'applies sort order ascending' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_order: 'asc')
      expect(sql).to include('ASC')
    end

    it 'applies sort order descending' do
      sql = nil
      allow(db).to receive(:fetch) do |query|
        sql = query
        double(all: movies)
      end
      
      described_class.filtered(sort_order: 'desc')
      expect(sql).to include('DESC')
    end

    it 'handles empty search string' do
      described_class.filtered(search: '')
      # Should not add search condition
    end

    it 'handles nil filters gracefully' do
      expect { described_class.filtered(nil) }.not_to raise_error
    end
  end

  describe '.find' do
    let(:movie) do
      {
        movie_id: 1,
        movie_name: 'Test Movie',
        release_date: Date.today,
        runtime_minutes: 120
      }
    end

    context 'when movie exists' do
      before do
        allow(db).to receive(:fetch).and_return(double(first: movie))
      end

      it 'returns movie with basic details' do
        result = described_class.find(1)
        expect(result[:movie_name]).to eq('Test Movie')
      end

      it 'includes all associations' do
        result = described_class.find(1)
        expect(result).to have_key(:directors)
        expect(result).to have_key(:writers)
        expect(result).to have_key(:cast)
        expect(result).to have_key(:files)
      end

      it 'loads directors' do
        allow(@dataset).to receive(:select_map).and_return(['Director One', 'Director Two'])
        
        result = described_class.find(1)
        expect(result[:directors]).to eq(['Director One', 'Director Two'])
      end

      it 'loads writers with credit types' do
        writers = [
          { person_id: 1, full_name: 'Writer One', credit_type_name: 'Screenplay' },
          { person_id: 2, full_name: 'Writer Two', credit_type_name: 'Story' }
        ]
        allow(@dataset).to receive(:all).and_return(writers)
        
        result = described_class.find(1)
        expect(result[:writers]).to eq(writers)
      end

      it 'loads cast ordered by billing' do
        cast = [
          { cast_id: 1, full_name: 'Actor One', character_name: 'Hero', billing_order: 1 },
          { cast_id: 2, full_name: 'Actor Two', character_name: 'Villain', billing_order: 2 }
        ]
        allow(@dataset).to receive(:all).and_return(cast)
        
        result = described_class.find(1)
        expect(result[:cast]).to eq(cast)
      end

      it 'loads files with technical details' do
        files = [
          {
            file_id: 1,
            file_name: 'movie.mkv',
            resolution_name: '1080p',
            video_codec: 'H.264'
          }
        ]
        allow(@dataset).to receive(:all).and_return(files)
        
        result = described_class.find(1)
        expect(result[:files].first).to include(:audio_tracks, :subtitles)
      end

      it 'loads audio tracks for each file' do
        files = [{ file_id: 1 }]
        audio_tracks = [
          { track_id: 1, language: 'English', codec: 'DTS', channels: '5.1' }
        ]
        
        allow(@dataset).to receive(:all).and_return(files, audio_tracks, [])
        
        result = described_class.find(1)
        expect(result[:files].first[:audio_tracks]).to eq(audio_tracks)
      end

      it 'loads subtitles for each file' do
        files = [{ file_id: 1 }]
        subtitles = [
          { subtitle_id: 1, language: 'English', format: 'SRT' }
        ]
        
        allow(@dataset).to receive(:all).and_return(files, [], subtitles)
        
        result = described_class.find(1)
        expect(result[:files].first[:subtitles]).to eq(subtitles)
      end
    end

    context 'when movie does not exist' do
      before do
        allow(db).to receive(:fetch).and_return(double(first: nil))
      end

      it 'returns nil' do
        expect(described_class.find(999)).to be_nil
      end
    end
  end

  describe '.genres' do
    it 'returns ordered genres' do
      genres = [
        { genre_id: 1, genre_name: 'Action' },
        { genre_id: 2, genre_name: 'Drama' }
      ]
      allow(@dataset).to receive(:all).and_return(genres)
      
      result = described_class.genres
      expect(result).to eq(genres)
    end

    it 'handles empty table' do
      allow(@dataset).to receive(:all).and_return([])
      
      result = described_class.genres
      expect(result).to eq([])
    end
  end

  describe '.countries' do
    it 'returns ordered countries' do
      countries = [
        { country_id: 1, country_name: 'USA' },
        { country_id: 2, country_name: 'UK' }
      ]
      allow(@dataset).to receive(:all).and_return(countries)
      
      result = described_class.countries
      expect(result).to eq(countries)
    end
  end

  describe '.languages' do
    it 'returns ordered languages' do
      languages = [
        { language_id: 1, language_name: 'English' },
        { language_id: 2, language_name: 'Spanish' }
      ]
      allow(@dataset).to receive(:all).and_return(languages)
      
      result = described_class.languages
      expect(result).to eq(languages)
    end
  end

  describe '.franchises' do
    it 'returns ordered franchises' do
      franchises = [
        { franchise_id: 1, franchise_name: 'Marvel' },
        { franchise_id: 2, franchise_name: 'DC' }
      ]
      allow(@dataset).to receive(:all).and_return(franchises)
      
      result = described_class.franchises
      expect(result).to eq(franchises)
    end
  end

  describe '.years' do
    it 'extracts distinct years in descending order' do
      years = [{ year: 2023 }, { year: 2022 }, { year: 2021 }]
      allow(@dataset).to receive(:map) { |&block| years.map(&block) }
      
      result = described_class.years
      expect(result).to eq([2023, 2022, 2021])
    end

    it 'handles nil release dates' do
      expect(@dataset).to receive(:exclude).with(release_date: nil).and_return(@dataset)
      
      described_class.years
    end

    it 'returns integers' do
      years = [{ year: '2023' }, { year: '2022' }]
      allow(@dataset).to receive(:map) { |&block| years.map(&block) }
      
      result = described_class.years
      expect(result).to all(be_a(Integer))
    end
  end

  it_behaves_like 'a filterable resource', 'movie'
end
