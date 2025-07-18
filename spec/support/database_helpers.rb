# frozen_string_literal: true

module DatabaseHelpers
  def setup_test_db
    # Mock database tables
    @movies_dataset = double('movies_dataset')
    @genres_dataset = double('genres_dataset')
    @people_dataset = double('people_dataset')
    @movie_files_dataset = double('movie_files_dataset')
    
    allow(DB).to receive(:[]) do |table|
      case table
      when :movies then @movies_dataset
      when :genres then @genres_dataset
      when :people then @people_dataset
      when :movie_files then @movie_files_dataset
      else double("#{table}_dataset")
      end
    end
  end

  def seed_test_data
    {
      movies: [
        { movie_id: 1, movie_name: 'Test Movie', release_date: Date.today, rating: 8.5 },
        { movie_id: 2, movie_name: 'Another Movie', release_date: Date.today - 365, rating: 7.0 }
      ],
      genres: [
        { genre_id: 1, genre_name: 'Action' },
        { genre_id: 2, genre_name: 'Drama' }
      ],
      people: [
        { person_id: 1, full_name: 'John Doe', tmdb_person_id: 123 },
        { person_id: 2, full_name: 'Jane Smith', tmdb_person_id: 456 }
      ]
    }
  end

  def create_movie(attrs = {})
    default = {
      movie_id: 1,
      movie_name: 'Test Movie',
      tmdb_id: 12345,
      release_date: Date.today,
      rating: 8.5,
      runtime_minutes: 120,
      description: 'A test movie'
    }
    default.merge(attrs)
  end

  def create_person(attrs = {})
    default = {
      person_id: 1,
      full_name: 'Test Person',
      tmdb_person_id: 123
    }
    default.merge(attrs)
  end

  def mock_db_connection
    db = double('database')
    allow(db).to receive(:extension)
    allow(db).to receive(:test_connection)
    allow(Sequel).to receive(:connect).and_return(db)
    db
  end

  def cleanup_test_files
    # Clean up any test files created during tests
    test_dirs = ['spec/fixtures/media', 'spec/tmp']
    test_dirs.each do |dir|
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end
  end
end

RSpec.configure do |config|
  config.include DatabaseHelpers
end
