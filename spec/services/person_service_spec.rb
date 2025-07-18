# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PersonService do
  let(:db) { mock_db_connection }
  
  before do
    stub_const('DB', db)
    
    @people_dataset = double('people_dataset')
    @movies_dataset = double('movies_dataset')
    
    allow(@people_dataset).to receive(:where).and_return(@people_dataset)
    allow(@people_dataset).to receive(:first).and_return(nil)
    
    allow(@movies_dataset).to receive(:join).and_return(@movies_dataset)
    allow(@movies_dataset).to receive(:where).and_return(@movies_dataset)
    allow(@movies_dataset).to receive(:order).and_return(@movies_dataset)
    allow(@movies_dataset).to receive(:select).and_return(@movies_dataset)
    allow(@movies_dataset).to receive(:all).and_return([])
    
    allow(db).to receive(:[]) do |table|
      case table
      when :people then @people_dataset
      when :movie_cast then @movies_dataset
      else double("#{table}_dataset")
      end
    end
    
    allow(Sequel).to receive(:desc).and_return(:desc)
  end

  describe '.find' do
    let(:person) do
      {
        person_id: 1,
        full_name: 'Tom Hanks',
        tmdb_person_id: 31,
        headshot_path: 'people/31/photo.jpg'
      }
    end

    context 'when person exists' do
      before do
        allow(@people_dataset).to receive(:first).and_return(person)
      end

      it 'returns person with basic details' do
        result = described_class.find(1)
        expect(result[:full_name]).to eq('Tom Hanks')
        expect(result[:person_id]).to eq(1)
      end

      it 'includes movies array' do
        result = described_class.find(1)
        expect(result).to have_key(:movies)
        expect(result[:movies]).to be_an(Array)
      end

      context 'with movies' do
        let(:movies) do
          [
            {
              movie_id: 1,
              movie_name: 'Forrest Gump',
              release_date: Date.new(1994, 7, 6),
              character_name: 'Forrest Gump',
              poster_path: 'movies/1/poster.jpg'
            },
            {
              movie_id: 2,
              movie_name: 'Cast Away',
              release_date: Date.new(2000, 12, 22),
              character_name: 'Chuck Noland',
              poster_path: 'movies/2/poster.jpg'
            }
          ]
        end

        before do
          allow(@movies_dataset).to receive(:all).and_return(movies)
        end

        it 'loads movies with character names' do
          result = described_class.find(1)
          expect(result[:movies]).to eq(movies)
          expect(result[:movies].first[:character_name]).to eq('Forrest Gump')
        end

        it 'orders movies by release date descending' do
          expect(@movies_dataset).to receive(:order).with(:desc)
          described_class.find(1)
        end

        it 'includes all movie fields' do
          result = described_class.find(1)
          movie = result[:movies].first
          expect(movie).to have_key(:movie_id)
          expect(movie).to have_key(:movie_name)
          expect(movie).to have_key(:release_date)
          expect(movie).to have_key(:character_name)
          expect(movie).to have_key(:poster_path)
        end
      end

      context 'with no movies' do
        before do
          allow(@movies_dataset).to receive(:all).and_return([])
        end

        it 'returns empty movies array' do
          result = described_class.find(1)
          expect(result[:movies]).to eq([])
        end
      end

      context 'with complex filmography' do
        let(:complex_movies) do
          # Mix of different roles and years
          (1..20).map do |i|
            {
              movie_id: i,
              movie_name: "Movie #{i}",
              release_date: Date.today - (i * 365),
              character_name: "Character #{i}",
              poster_path: "movies/#{i}/poster.jpg"
            }
          end
        end

        before do
          allow(@movies_dataset).to receive(:all).and_return(complex_movies)
        end

        it 'handles large filmography' do
          result = described_class.find(1)
          expect(result[:movies].size).to eq(20)
        end

        it 'maintains order' do
          result = described_class.find(1)
          dates = result[:movies].map { |m| m[:release_date] }
          expect(dates).to eq(dates.sort.reverse)
        end
      end
    end

    context 'when person does not exist' do
      before do
        allow(@people_dataset).to receive(:first).and_return(nil)
      end

      it 'returns nil' do
        expect(described_class.find(999)).to be_nil
      end

      it 'does not query movies' do
        expect(@movies_dataset).not_to receive(:all)
        described_class.find(999)
      end
    end

    context 'with database errors' do
      it 'handles connection errors' do
        allow(@people_dataset).to receive(:where)
          .and_raise(Sequel::DatabaseConnectionError.new('Connection lost'))
        
        expect { described_class.find(1) }.to raise_error(Sequel::DatabaseConnectionError)
      end

      it 'handles query errors in movie loading' do
        allow(@people_dataset).to receive(:first).and_return(person)
        allow(@movies_dataset).to receive(:all)
          .and_raise(Sequel::DatabaseError.new('Query failed'))
        
        expect { described_class.find(1) }.to raise_error(Sequel::DatabaseError)
      end
    end

    context 'query construction' do
      it 'queries correct person' do
        expect(@people_dataset).to receive(:where).with(person_id: 123)
          .and_return(@people_dataset)
        
        described_class.find(123)
      end

      it 'joins correct tables for movies' do
        allow(@people_dataset).to receive(:first).and_return(person)
        
        expect(db).to receive(:[]).with(:movie_cast).and_return(@movies_dataset)
        expect(@movies_dataset).to receive(:join).with(:movies, movie_id: :movie_id)
          .and_return(@movies_dataset)
        
        described_class.find(1)
      end

      it 'filters movies by person_id' do
        allow(@people_dataset).to receive(:first).and_return(person)
        
        expect(@movies_dataset).to receive(:where) do |hash|
          expect(hash.values.first).to eq(1)
          @movies_dataset
        end
        
        described_class.find(1)
      end

      it 'selects correct movie fields' do
        allow(@people_dataset).to receive(:first).and_return(person)
        
        expect(@movies_dataset).to receive(:select) do |*fields|
          # Check that necessary fields are selected
          field_symbols = fields.map { |f| f.is_a?(Symbol) ? f : nil }.compact
          expect(field_symbols).to include(:movie_name, :release_date, :character_name, :poster_path)
          @movies_dataset
        end
        
        described_class.find(1)
      end
    end

    context 'edge cases' do
      it 'handles nil person_id gracefully' do
        expect { described_class.find(nil) }.not_to raise_error
        expect(described_class.find(nil)).to be_nil
      end

      it 'handles string person_id' do
        expect(@people_dataset).to receive(:where).with(person_id: '123')
        described_class.find('123')
      end

      it 'handles person with nil values' do
        person_with_nils = {
          person_id: 1,
          full_name: 'Unknown',
          tmdb_person_id: nil,
          headshot_path: nil
        }
        
        allow(@people_dataset).to receive(:first).and_return(person_with_nils)
        
        result = described_class.find(1)
        expect(result[:full_name]).to eq('Unknown')
        expect(result[:headshot_path]).to be_nil
      end

      it 'handles movies with nil release dates' do
        allow(@people_dataset).to receive(:first).and_return(person)
        
        movies_with_nils = [
          { movie_id: 1, movie_name: 'Test', release_date: nil }
        ]
        allow(@movies_dataset).to receive(:all).and_return(movies_with_nils)
        
        result = described_class.find(1)
        expect(result[:movies].first[:release_date]).to be_nil
      end
    end
  end

  describe 'performance considerations' do
    it 'uses single query for person' do
      expect(@people_dataset).to receive(:where).once
      expect(@people_dataset).to receive(:first).once
      
      described_class.find(1)
    end

    it 'uses single query for all movies' do
      allow(@people_dataset).to receive(:first).and_return({ person_id: 1 })
      
      expect(@movies_dataset).to receive(:all).once
      
      described_class.find(1)
    end
  end
end
