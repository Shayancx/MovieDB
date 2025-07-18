# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatisticsService do
  let(:db) { mock_db_connection }
  
  before do
    stub_const('DB', db)
    
    # Setup dataset mocks
    @movies_dataset = double('movies_dataset')
    @files_dataset = double('files_dataset')
    @genres_dataset = double('genres_dataset')
    @years_dataset = double('years_dataset')
    
    allow(@movies_dataset).to receive(:count).and_return(100)
    allow(@movies_dataset).to receive(:sum).with(:runtime_minutes).and_return(12000)
    allow(@movies_dataset).to receive(:where).and_return(@years_dataset)
    allow(@movies_dataset).to receive(:group_and_count).and_return(@years_dataset)
    
    allow(@files_dataset).to receive(:sum).with(:file_size_mb).and_return(1048576)
    
    allow(@genres_dataset).to receive(:join).and_return(@genres_dataset)
    allow(@genres_dataset).to receive(:group_and_count).and_return(@genres_dataset)
    allow(@genres_dataset).to receive(:order).and_return(@genres_dataset)
    allow(@genres_dataset).to receive(:limit).and_return(@genres_dataset)
    allow(@genres_dataset).to receive(:all).and_return([])
    
    allow(@years_dataset).to receive(:order).and_return(@years_dataset)
    allow(@years_dataset).to receive(:all).and_return([])
    
    allow(db).to receive(:[]) do |table|
      case table
      when :movies then @movies_dataset
      when :movie_files then @files_dataset
      when :movie_genres then @genres_dataset
      else double("#{table}_dataset")
      end
    end
    
    allow(Sequel).to receive(:desc).and_return(:desc)
    allow(Sequel).to receive(:function).and_return(double(as: :year))
  end

  describe '.summary' do
    let(:expected_summary) do
      {
        total_movies: 100,
        total_size_gb: 1024.0,
        total_runtime_hours: 200,
        movies_per_genre: [],
        movies_per_year: []
      }
    end

    it 'returns complete summary hash' do
      summary = described_class.summary
      expect(summary).to be_a(Hash)
      expect(summary.keys).to match_array(expected_summary.keys)
    end

    describe 'total calculations' do
      it 'calculates total movies count' do
        expect(@movies_dataset).to receive(:count).and_return(150)
        
        summary = described_class.summary
        expect(summary[:total_movies]).to eq(150)
      end

      it 'calculates total size in GB' do
        expect(@files_dataset).to receive(:sum).with(:file_size_mb).and_return(2097152)
        
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(2048.0)
      end

      it 'calculates total runtime in hours' do
        expect(@movies_dataset).to receive(:sum).with(:runtime_minutes).and_return(18000)
        
        summary = described_class.summary
        expect(summary[:total_runtime_hours]).to eq(300)
      end

      it 'rounds size to 2 decimal places' do
        expect(@files_dataset).to receive(:sum).and_return(1234567)
        
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(1205.63)
      end

      it 'rounds runtime hours to nearest integer' do
        expect(@movies_dataset).to receive(:sum).and_return(12029) # 200.48 hours
        
        summary = described_class.summary
        expect(summary[:total_runtime_hours]).to eq(200)
      end
    end

    describe 'handling nil values' do
      it 'handles nil file size sum' do
        expect(@files_dataset).to receive(:sum).and_return(nil)
        
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(0)
      end

      it 'handles nil runtime sum' do
        expect(@movies_dataset).to receive(:sum).and_return(nil)
        
        summary = described_class.summary
        expect(summary[:total_runtime_hours]).to eq(0)
      end
    end

    describe 'empty database' do
      before do
        allow(@movies_dataset).to receive(:count).and_return(0)
        allow(@files_dataset).to receive(:sum).and_return(nil)
        allow(@movies_dataset).to receive(:sum).and_return(nil)
      end

      it 'returns zeros for empty database' do
        summary = described_class.summary
        expect(summary[:total_movies]).to eq(0)
        expect(summary[:total_size_gb]).to eq(0)
        expect(summary[:total_runtime_hours]).to eq(0)
      end
    end

    describe 'genre statistics' do
      let(:genre_data) do
        [
          { genre_name: 'Action', count: 45 },
          { genre_name: 'Drama', count: 38 },
          { genre_name: 'Comedy', count: 32 },
          { genre_name: 'Thriller', count: 28 },
          { genre_name: 'Sci-Fi', count: 25 }
        ]
      end

      before do
        allow(@genres_dataset).to receive(:all).and_return(genre_data)
      end

      it 'returns top 10 genres by count' do
        expect(@genres_dataset).to receive(:limit).with(10)
        
        summary = described_class.summary
        expect(summary[:movies_per_genre]).to eq(genre_data)
      end

      it 'orders genres by count descending' do
        expect(@genres_dataset).to receive(:order).with(:desc)
        
        described_class.summary
      end

      it 'joins correct tables' do
        expect(db).to receive(:[]).with(:movie_genres).and_return(@genres_dataset)
        expect(@genres_dataset).to receive(:join).with(:genres, genre_id: :genre_id)
        
        described_class.summary
      end

      it 'groups by genre name' do
        expect(@genres_dataset).to receive(:group_and_count).with(:genre_name)
        
        described_class.summary
      end
    end

    describe 'year statistics' do
      let(:year_data) do
        [
          { year: 2023, count: 15 },
          { year: 2022, count: 20 },
          { year: 2021, count: 18 }
        ]
      end

      before do
        allow(@years_dataset).to receive(:all).and_return(year_data)
      end

      it 'returns movies per year' do
        summary = described_class.summary
        expect(summary[:movies_per_year]).to eq(year_data)
      end

      it 'filters out nil release dates' do
        expect(@movies_dataset).to receive(:where) do |&block|
          # Test the block filters nil dates
          expect(block.call(double(release_date: nil))).to be_falsey
          expect(block.call(double(release_date: Date.today))).to be_truthy
          @years_dataset
        end
        
        described_class.summary
      end

      it 'orders by year descending' do
        expect(@years_dataset).to receive(:order).with(:desc)
        
        described_class.summary
      end
    end

    describe 'large datasets' do
      before do
        allow(@movies_dataset).to receive(:count).and_return(10_000)
        allow(@files_dataset).to receive(:sum).and_return(10_737_418_240) # 10TB in MB
        allow(@movies_dataset).to receive(:sum).and_return(1_200_000) # 20,000 hours
        
        # Generate large genre dataset
        large_genres = (1..15).map { |i| { genre_name: "Genre#{i}", count: 1000 - i * 50 } }
        allow(@genres_dataset).to receive(:all).and_return(large_genres.take(10))
        
        # Generate years from 1920 to 2023
        large_years = (1920..2023).map { |y| { year: y, count: rand(1..100) } }.reverse
        allow(@years_dataset).to receive(:all).and_return(large_years)
      end

      it 'handles large movie counts' do
        summary = described_class.summary
        expect(summary[:total_movies]).to eq(10_000)
      end

      it 'handles large file sizes correctly' do
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(10_485.76) # 10TB
      end

      it 'handles large runtime totals' do
        summary = described_class.summary
        expect(summary[:total_runtime_hours]).to eq(20_000)
      end

      it 'limits genres to top 10' do
        summary = described_class.summary
        expect(summary[:movies_per_genre].size).to eq(10)
      end
    end

    describe 'floating point precision' do
      it 'maintains precision for file sizes' do
        expect(@files_dataset).to receive(:sum).and_return(1234.56) # MB
        
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(1.21) # Rounded to 2 decimals
      end

      it 'maintains precision for very small sizes' do
        expect(@files_dataset).to receive(:sum).and_return(0.5) # 0.5 MB
        
        summary = described_class.summary
        expect(summary[:total_size_gb]).to eq(0.0) # Less than 0.01 GB
      end

      it 'handles very precise runtime calculations' do
        expect(@movies_dataset).to receive(:sum).and_return(123.456) # minutes
        
        summary = described_class.summary
        expect(summary[:total_runtime_hours]).to eq(2) # Rounded to nearest hour
      end
    end

    describe 'database errors' do
      it 'handles connection errors' do
        allow(@movies_dataset).to receive(:count)
          .and_raise(Sequel::DatabaseConnectionError.new('Connection lost'))
        
        expect { described_class.summary }.to raise_error(Sequel::DatabaseConnectionError)
      end

      it 'handles query errors' do
        allow(@genres_dataset).to receive(:all)
          .and_raise(Sequel::DatabaseError.new('Query failed'))
        
        expect { described_class.summary }.to raise_error(Sequel::DatabaseError)
      end
    end

    describe 'performance optimizations' do
      it 'uses efficient counting' do
        expect(@movies_dataset).to receive(:count).once
        described_class.summary
      end

      it 'uses SQL aggregation for sums' do
        expect(@files_dataset).to receive(:sum).with(:file_size_mb).once
        expect(@movies_dataset).to receive(:sum).with(:runtime_minutes).once
        
        described_class.summary
      end

      it 'limits genre query results' do
        expect(@genres_dataset).to receive(:limit).with(10)
        described_class.summary
      end
    end
  end
end
