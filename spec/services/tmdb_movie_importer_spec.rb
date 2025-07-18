# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tempfile'

require_relative '../../app/services/tmdb_movie_importer'

RSpec.describe TMDBMovieImporter do
  let(:importer) { described_class.new }
  let(:test_directory) { Dir.mktmpdir }

  # Mocks for dependencies
  let(:db_service) { instance_double(DatabaseService) }
  let(:tmdb_client) { instance_double(TmdbClient) }
  let(:thread_pool) { instance_double(Concurrent::ThreadPoolExecutor, post: nil, shutdown: nil, wait_for_termination: nil) }

  before do
    # Stub dependencies to avoid actual DB/API calls
    allow(DatabaseService).to receive(:new).and_return(db_service)
    allow(TmdbClient).to receive(:new).and_return(tmdb_client)
    allow(Concurrent::ThreadPoolExecutor).to receive(:new).and_return(thread_pool)

    # Make thread pool execute tasks immediately for synchronous testing
    allow(thread_pool).to receive(:post).and_yield

    # Default stubs for mock objects
    allow(db_service).to receive(:get_existing_file_paths).and_return(Set.new)
    allow(db_service).to receive(:insert_movie).and_return(1)
    allow(db_service).to receive(:bulk_import_associations).and_return({})
    allow(db_service).to receive(:insert_movie_file).and_return(10)
    allow(db_service).to receive(:update_record)
    allow(db_service).to receive(:close)
    allow(tmdb_client).to receive(:get_movie_details).and_return(build_movie_details)
    allow(tmdb_client).to receive(:search_movie).and_return([])
    allow(tmdb_client).to receive(:download_image).and_return('path/to/image.jpg')

    # Mock TUI and PrettyLogger to suppress output
    allow(TUI).to receive(:start)
    allow(TUI).to receive(:increment)
    allow(TUI).to receive(:finish)
    allow(PrettyLogger).to receive(:info)
    allow(PrettyLogger).to receive(:warn)
    allow(PrettyLogger).to receive(:error)
    allow(PrettyLogger).to receive(:success)
    allow(PrettyLogger).to receive(:debug)

    # Mock FileUtils to avoid actual file system changes
    allow(FileUtils).to receive(:mkdir_p)
  end

  after do
    FileUtils.rm_rf(test_directory)
    # Manually shutdown to avoid at_exit conflicts
    importer.shutdown unless importer.instance_variable_get(:@shutdown_started)
  end

  describe '#import_from_directory' do
    context 'with new movie files' do
      before do
        # Create a dummy file for the test
        FileUtils.touch(File.join(test_directory, 'Inception (2010).mkv'))
      end

      it 'processes new files' do
        # Expect process_movie_file to be called for the new file
        expect(importer).to receive(:process_movie_file).once
        importer.import_from_directory(test_directory)
      end

      it 'displays a correct scan summary' do
        expect(PrettyLogger).to receive(:info).with(/1 new movie to be imported/)
        importer.import_from_directory(test_directory)
      end
    end

    context 'with no new files' do
      it 'does not process any files' do
        allow(db_service).to receive(:get_existing_file_paths).and_return(Set.new(['/path/to/movie.mkv']))
        expect(importer).not_to receive(:process_files)
        importer.import_from_directory(test_directory)
      end
    end

    context 'with permission errors during scan' do
      it 'logs an error and returns an empty array' do
        allow(Dir).to receive(:glob).and_raise(Errno::EACCES)
        expect(PrettyLogger).to receive(:error).with(/Permission denied/)
        expect(importer.send(:find_movie_files, test_directory)).to eq([])
      end
    end
  end

  describe '#process_movie_file' do
    it 'handles parsing failure gracefully' do
      allow(importer).to receive(:parse_filename).and_return(nil)
      expect(PrettyLogger).to receive(:error).with(/Could not parse movie info/)
      importer.send(:process_movie_file, 'invalid-filename.mkv')
    end

    it 'handles TMDB lookup failure gracefully' do
      allow(importer).to receive(:parse_filename).and_return({ name: 'Unknown', year: 2000 })
      allow(tmdb_client).to receive(:get_movie_details).and_return(nil)
      allow(tmdb_client).to receive(:search_movie).and_return([])
      expect(PrettyLogger).to receive(:error).with(/Could not find TMDB details/)
      importer.send(:process_movie_file, 'Unknown (2000).mkv')
    end
  end

  describe '#parse_filename' do
    it 'parses name, year, and TMDB ID correctly' do
      result = importer.send(:parse_filename, 'Inception (2010) (tmdbid-27205).mkv')
      expect(result).to eq({ name: 'Inception', year: 2010, tmdb_id: 27205 })
    end

    it 'parses name and year correctly' do
      result = importer.send(:parse_filename, 'The.Dark.Knight (2008).mp4')
      expect(result).to eq({ name: 'The Dark Knight', year: 2008 })
    end

    it 'returns nil for invalid formats' do
      expect(importer.send(:parse_filename, 'Movie.mkv')).to be_nil
    end
  end

  describe '#shutdown' do
    it 'shuts down the thread pool and closes the database connection' do
      expect(thread_pool).to receive(:shutdown)
      expect(thread_pool).to receive(:wait_for_termination).with(30)
      expect(db_service).to receive(:close)
      importer.shutdown
    end

    it 'only runs once' do
      expect(db_service).to receive(:close).once
      importer.shutdown
      importer.shutdown # Second call should be ignored
    end
  end

  describe '#enqueue_download' do
    it 'posts a download task to the thread pool' do
      expect(thread_pool).to receive(:post)
      importer.send(:enqueue_download, :movies, :poster_path, 1, '/poster.jpg', 'movies/1/poster.jpg')
    end

    it 'increments and decrements the pending task counter' do
      pending_tasks = importer.instance_variable_get(:@pending_tasks)
      expect(pending_tasks.value).to eq(0)
      importer.send(:enqueue_download, :movies, :poster_path, 1, '/poster.jpg', 'movies/1/poster.jpg')
      expect(pending_tasks.value).to eq(0) # Incremented and then decremented due to sync execution
    end
  end

  describe '#enqueue_checksum_calculation' do
    it 'posts a checksum calculation task to the thread pool' do
      allow(Digest::SHA256).to receive_message_chain(:file, :hexdigest).and_return('checksum')
      expect(thread_pool).to receive(:post)
      importer.send(:enqueue_checksum_calculation, 1, 'movie.mkv')
    end
  end
end

def build_movie_details
  {
    'id' => 27205,
    'title' => 'Inception',
    'original_language' => 'en',
    'images' => {
      'posters' => [{ 'file_path' => '/poster.jpg', 'iso_639_1' => 'en' }],
      'backdrops' => [{ 'file_path' => '/backdrop.jpg', 'iso_639_1' => 'en' }],
      'logos' => []
    },
    'credits' => {
      'cast' => [{ 'id' => 1, 'profile_path' => '/profile.jpg' }]
    }
  }
end
