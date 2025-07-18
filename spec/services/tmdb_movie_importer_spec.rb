# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tempfile'

RSpec.describe TMDBMovieImporter do
  let(:db) { mock_db_connection }
  let(:importer) { described_class.new }
  let(:test_directory) { Dir.mktmpdir }
  
  before do
    stub_const('DB', db)
    stub_const('TMDBMovieImporter::MAX_BG_THREADS', 2)
    
    # Mock DatabaseService
    @db_service = instance_double(DatabaseService)
    allow(DatabaseService).to receive(:new).and_return(@db_service)
    allow(@db_service).to receive(:conn).and_return(db)
    allow(@db_service).to receive(:get_existing_file_paths).and_return(Set.new)
    allow(@db_service).to receive(:insert_movie).and_return(1)
    allow(@db_service).to receive(:bulk_import_associations)
    allow(@db_service).to receive(:insert_movie_file).and_return(1)
    allow(@db_service).to receive(:update_record)
    allow(@db_service).to receive(:close)
    
    # Mock TmdbClient
    @tmdb_client = instance_double(TmdbClient)
    allow(TmdbClient).to receive(:new).and_return(@tmdb_client)
    allow(@tmdb_client).to receive(:search_movie).and_return([])
    allow(@tmdb_client).to receive(:get_movie_details).and_return(nil)
    allow(@tmdb_client).to receive(:download_image).and_return(nil)
    
    # Mock transaction
    allow(db).to receive(:transaction).and_yield
    
    # Mock MediaInfoParser
    allow(MediaInfoParser).to receive(:new).and_return(
      double(valid?: true, width: 1920, height: 1080)
    )
    
    # Mock FileUtils
    allow(FileUtils).to receive(:mkdir_p)
    
    # Mock PrettyLogger
    allow(PrettyLogger).to receive(:info)
    allow(PrettyLogger).to receive(:error)
    allow(PrettyLogger).to receive(:warn)
    allow(PrettyLogger).to receive(:success)
    allow(PrettyLogger).to receive(:debug)
    
    # Mock TUI
    allow(TUI).to receive(:start)
    allow(TUI).to receive(:increment)
    allow(TUI).to receive(:finish)
    
    # Suppress console output during tests
    allow($stdin).to receive(:gets).and_return("1\n")
  end
  
  after do
    FileUtils.rm_rf(test_directory)
  end

  describe '#initialize' do
    it 'sets up thread pool with correct size' do
      pool = importer.instance_variable_get(:@thread_pool)
      expect(pool).to be_a(Concurrent::ThreadPoolExecutor)
      expect(pool.max_length).to eq(2)
    end

    it 'creates database update queue' do
      queue = importer.instance_variable_get(:@db_update_queue)
      expect(queue).to be_a(Queue)
    end

    it 'starts database updater thread' do
      thread = importer.instance_variable_get(:@db_updater_thread)
      expect(thread).to be_a(Thread)
      expect(thread).to be_alive
    end

    it 'sets up media directories' do
      expect(FileUtils).to have_received(:mkdir_p).at_least(:twice)
    end
  end

  describe '#import_from_directory' do
    context 'with new movie files' do
      let(:movie_file) { File.join(test_directory, 'Inception (2010).mkv') }
      let(:movie_details) { build_movie_details }
      
      before do
        FileUtils.touch(movie_file)
        allow(Dir).to receive(:glob).and_return([movie_file])
        allow(@tmdb_client).to receive(:get_movie_details).and_return(movie_details)
      end

      it 'processes new files' do
        expect(importer).to receive(:process_movie_file).with(movie_file)
        importer.import_from_directory(test_directory)
      end

      it 'displays scan summary' do
        expect(PrettyLogger).to receive(:info).with(/Scan Complete/)
        expect(PrettyLogger).to receive(:success).with(/0 movies are already/)
        expect(PrettyLogger).to receive(:info).with(/1 new movies will be imported/)
        
        importer.import_from_directory(test_directory)
      end

      it 'starts and finishes TUI' do
        expect(TUI).to receive(:start).with(1)
        expect(TUI).to receive(:finish)
        
        importer.import_from_directory(test_directory)
      end
    end

    context 'with existing files' do
      let(:existing_file) { File.join(test_directory, 'Existing.mkv') }
      
      before do
        FileUtils.touch(existing_file)
        allow(Dir).to receive(:glob).and_return([existing_file])
        allow(@db_service).to receive(:get_existing_file_paths)
          .and_return(Set.new([File.absolute_path(existing_file)]))
      end

      it 'skips existing files' do
        expect(importer).not_to receive(:process_movie_file)
        importer.import_from_directory(test_directory)
      end

      it 'reports correct counts' do
        expect(PrettyLogger).to receive(:success).with(/1 movies are already/)
        expect(PrettyLogger).to receive(:info).with(/0 new movies will be imported/)
        
        importer.import_from_directory(test_directory)
      end
    end

    context 'with various file extensions' do
      it 'finds all video files' do
        video_files = %w[movie.mkv movie.mp4 movie.mov movie.avi movie.m2ts]
        video_files.each { |f| FileUtils.touch(File.join(test_directory, f)) }
        
        allow(Dir).to receive(:glob).and_call_original
        
        importer.import_from_directory(test_directory)
        
        expect(Dir).to have_received(:glob)
          .with(File.join(test_directory, '**', '*.{mkv,mp4,mov,avi,m2ts}'), File::FNM_CASEFOLD)
      end
    end

    context 'with empty directory' do
      before do
        allow(Dir).to receive(:glob).and_return([])
      end

      it 'handles empty directory gracefully' do
        expect { importer.import_from_directory(test_directory) }.not_to raise_error
      end

      it 'does not start TUI' do
        expect(TUI).not_to receive(:start)
        importer.import_from_directory(test_directory)
      end
    end

    context 'with permission errors' do
      let(:inaccessible_file) { File.join(test_directory, 'NoAccess.mkv') }
      
      before do
        FileUtils.touch(inaccessible_file)
        allow(Dir).to receive(:glob).and_return([inaccessible_file])
        allow(File).to receive(:absolute_path).with(inaccessible_file)
          .and_raise(Errno::EACCES)
      end

      it 'handles permission errors gracefully' do
        expect { importer.import_from_directory(test_directory) }.not_to raise_error
      end
    end
  end

  describe '#process_movie_file' do
    let(:movie_file) { 'Inception (2010).mkv' }
    let(:movie_details) { build_movie_details }
    let(:parsed_info) { { name: 'Inception', year: 2010 } }
    
    before do
      allow(importer).to receive(:parse_filename).and_return(parsed_info)
      allow(importer).to receive(:fetch_movie_details).and_return(movie_details)
      allow(importer).to receive(:process_technical_data)
      allow(importer).to receive(:enqueue_image_downloads)
    end

    it 'updates TUI with filename' do
      expect(TUI).to receive(:increment).with('Inception (2010).mkv')
      importer.send(:process_movie_file, movie_file)
    end

    context 'with successful import flow' do
      it 'executes complete import process' do
        expect(@db_service).to receive(:insert_movie).with(movie_details).and_return(1)
        expect(@db_service).to receive(:bulk_import_associations).with(1, movie_details)
        expect(importer).to receive(:process_technical_data).with(1, movie_file)
        expect(importer).to receive(:enqueue_image_downloads).with(1, movie_details)
        
        importer.send(:process_movie_file, movie_file)
      end

      it 'wraps operations in transaction' do
        expect(db).to receive(:transaction).and_yield
        importer.send(:process_movie_file, movie_file)
      end
    end

    context 'with parsing failures' do
      before do
        allow(importer).to receive(:parse_filename).and_return(nil)
      end

      it 'logs error and returns early' do
        expect(PrettyLogger).to receive(:error).with(/Could not parse movie info/)
        expect(@db_service).not_to receive(:insert_movie)
        
        importer.send(:process_movie_file, movie_file)
      end
    end

    context 'with TMDB lookup failures' do
      before do
        allow(importer).to receive(:fetch_movie_details).and_return(nil)
      end

      it 'logs error and returns early' do
        expect(PrettyLogger).to receive(:error).with(/Could not find TMDB details/)
        expect(@db_service).not_to receive(:insert_movie)
        
        importer.send(:process_movie_file, movie_file)
      end
    end

    context 'with database transaction rollback' do
      before do
        allow(db).to receive(:transaction).and_raise(Sequel::Rollback)
      end

      it 'handles rollback gracefully' do
        expect { importer.send(:process_movie_file, movie_file) }.not_to raise_error
      end
    end

    context 'with unexpected errors' do
      before do
        allow(@db_service).to receive(:insert_movie)
          .and_raise(StandardError.new('Database error'))
      end

      it 'logs fatal error with backtrace' do
        expect(PrettyLogger).to receive(:error).with(/Fatal error processing/)
        expect(PrettyLogger).to receive(:debug)
        
        importer.send(:process_movie_file, movie_file)
      end
    end
  end

  describe '#parse_filename' do
    context 'standard format "Movie (Year).ext"' do
      it 'parses name and year' do
        result = importer.send(:parse_filename, 'The Matrix (1999).mkv')
        expect(result).to eq(name: 'The Matrix', year: 1999)
      end

      it 'handles spaces in title' do
        result = importer.send(:parse_filename, 'The Dark Knight (2008).mp4')
        expect(result).to eq(name: 'The Dark Knight', year: 2008)
      end
    end

    context 'with TMDB ID format' do
      it 'parses name, year and tmdb id' do
        result = importer.send(:parse_filename, 'Inception (2010) (tmdbid-27205).mkv')
        expect(result).to eq(name: 'Inception', year: 2010, tmdb_id: 27205)
      end

      it 'handles case variations' do
        result = importer.send(:parse_filename, 'Movie (2020) (TMDBID-123).mkv')
        expect(result).to eq(name: 'Movie', year: 2020, tmdb_id: 123)
      end
    end

    context 'with dots instead of spaces' do
      it 'converts dots to spaces' do
        result = importer.send(:parse_filename, 'The.Matrix.1999 (1999).mp4')
        expect(result).to eq(name: 'The Matrix 1999', year: 1999)
      end
    end

    context 'invalid formats' do
      it 'returns nil for missing year' do
        expect(importer.send(:parse_filename, 'Movie.mkv')).to be_nil
      end

      it 'returns nil for invalid year format' do
        expect(importer.send(:parse_filename, 'Movie (abcd).mkv')).to be_nil
      end

      it 'returns nil for empty filename' do
        expect(importer.send(:parse_filename, '')).to be_nil
      end
    end

    context 'special characters' do
      it 'handles apostrophes' do
        result = importer.send(:parse_filename, "Ocean's Eleven (2001).mkv")
        expect(result[:name]).to eq("Ocean's Eleven")
      end

      it 'handles colons' do
        result = importer.send(:parse_filename, 'Mission: Impossible (1996).mkv')
        expect(result[:name]).to eq('Mission: Impossible')
      end
    end
  end

  describe '#fetch_movie_details' do
    let(:parsed_info) { { name: 'Inception', year: 2010 } }
    let(:movie_details) { build_movie_details }
    let(:search_results) do
      [
        { 'id' => 27205, 'title' => 'Inception', 'release_date' => '2010-07-16' },
        { 'id' => 12345, 'title' => 'Inception: Making Of', 'release_date' => '2010-12-07' }
      ]
    end

    context 'with TMDB ID provided' do
      let(:parsed_info) { { name: 'Inception', year: 2010, tmdb_id: 27205 } }

      it 'fetches directly without search' do
        expect(@tmdb_client).not_to receive(:search_movie)
        expect(@tmdb_client).to receive(:get_movie_details).with(27205)
          .and_return(movie_details)
        
        result = importer.send(:fetch_movie_details, parsed_info)
        expect(result).to eq(movie_details)
      end
    end

    context 'without TMDB ID' do
      before do
        allow(@tmdb_client).to receive(:search_movie)
          .with('Inception', 2010)
          .and_return(search_results)
      end

      context 'with single search result' do
        let(:search_results) { [{ 'id' => 27205, 'title' => 'Inception' }] }

        it 'automatically selects the only result' do
          expect(importer).not_to receive(:present_search_choices)
          expect(@tmdb_client).to receive(:get_movie_details).with(27205)
            .and_return(movie_details)
          
          result = importer.send(:fetch_movie_details, parsed_info)
          expect(result).to eq(movie_details)
        end
      end

      context 'with multiple search results' do
        it 'presents choices to user' do
          expect(importer).to receive(:present_search_choices)
            .with(search_results, 'Inception')
            .and_return(search_results.first)
          expect(@tmdb_client).to receive(:get_movie_details).with(27205)
            .and_return(movie_details)
          
          result = importer.send(:fetch_movie_details, parsed_info)
          expect(result).to eq(movie_details)
        end
      end

      context 'with no search results' do
        let(:search_results) { [] }

        it 'returns nil' do
          expect(@tmdb_client).not_to receive(:get_movie_details)
          
          result = importer.send(:fetch_movie_details, parsed_info)
          expect(result).to be_nil
        end
      end

      context 'when user chooses to skip' do
        before do
          allow(@tmdb_client).to receive(:search_movie).and_return(search_results)
          allow(importer).to receive(:present_search_choices).and_return(nil)
        end

        it 'returns nil' do
          result = importer.send(:fetch_movie_details, parsed_info)
          expect(result).to be_nil
        end
      end
    end
  end

  describe '#process_technical_data' do
    let(:movie_id) { 1 }
    let(:file_path) { '/path/to/movie.mkv' }
    let(:mediainfo) do
      double('mediainfo',
        valid?: true,
        width: 1920,
        height: 1080,
        file_format: 'MKV'
      )
    end

    before do
      allow(MediaInfoParser).to receive(:new).with(file_path).and_return(mediainfo)
    end

    context 'with valid mediainfo' do
      it 'inserts movie file and enqueues checksum' do
        expect(@db_service).to receive(:insert_movie_file)
          .with(movie_id, file_path, mediainfo)
          .and_return(10)
        expect(importer).to receive(:enqueue_checksum_calculation).with(10, file_path)
        
        importer.send(:process_technical_data, movie_id, file_path)
      end
    end

    context 'with invalid mediainfo' do
      before do
        allow(mediainfo).to receive(:valid?).and_return(false)
      end

      it 'logs warning and returns' do
        expect(PrettyLogger).to receive(:warn).with(/Could not read mediainfo/)
        expect(@db_service).not_to receive(:insert_movie_file)
        
        importer.send(:process_technical_data, movie_id, file_path)
      end
    end

    context 'when file insert returns nil' do
      before do
        allow(@db_service).to receive(:insert_movie_file).and_return(nil)
      end

      it 'does not enqueue checksum calculation' do
        expect(importer).not_to receive(:enqueue_checksum_calculation)
        
        importer.send(:process_technical_data, movie_id, file_path)
      end
    end
  end

  describe '#enqueue_image_downloads' do
    let(:movie_id) { 1 }
    let(:details) do
      {
        'images' => {
          'posters' => [
            { 'file_path' => '/poster_en.jpg', 'iso_639_1' => 'en' },
            { 'file_path' => '/poster_fr.jpg', 'iso_639_1' => 'fr' }
          ],
          'backdrops' => [
            { 'file_path' => '/backdrop.jpg', 'iso_639_1' => 'en' }
          ],
          'logos' => [
            { 'file_path' => '/logo.png', 'iso_639_1' => 'en' }
          ]
        },
        'original_language' => 'en'
      }
    end

    it 'enqueues downloads for all image types' do
      expect(importer).to receive(:enqueue_download).with(
        :movies, :poster_path, movie_id, '/poster_en.jpg', "movies/#{movie_id}/poster.jpg"
      )
      expect(importer).to receive(:enqueue_download).with(
        :movies, :backdrop_path, movie_id, '/backdrop.jpg', "movies/#{movie_id}/backdrop.jpg"
      )
      expect(importer).to receive(:enqueue_download).with(
        :movies, :logo_path, movie_id, '/logo.png', "movies/#{movie_id}/logo.png"
      )
      
      importer.send(:enqueue_image_downloads, movie_id, details)
    end

    it 'selects best image based on language preference' do
      expect(importer).to receive(:find_best_image)
        .with(details['images']['posters'], 'en')
        .and_call_original
      
      importer.send(:enqueue_image_downloads, movie_id, details)
    end

    context 'with missing images' do
      let(:details) { { 'images' => nil } }

      it 'handles gracefully' do
        expect { importer.send(:enqueue_image_downloads, movie_id, details) }.not_to raise_error
      end
    end
  end

  describe '#enqueue_download' do
    let(:thread_pool) { importer.instance_variable_get(:@thread_pool) }

    it 'posts download task to thread pool' do
      expect(thread_pool).to receive(:post)
      
      importer.send(:enqueue_download, :movies, :poster_path, 1, '/poster.jpg', 'movies/1/poster.jpg')
    end

    context 'when download succeeds' do
      before do
        allow(@tmdb_client).to receive(:download_image)
          .and_return('movies/1/poster.jpg')
      end

      it 'queues database update' do
        queue = importer.instance_variable_get(:@db_update_queue)
        
        importer.send(:enqueue_download, :movies, :poster_path, 1, '/poster.jpg', 'movies/1/poster.jpg')
        
        # Let the thread execute
        sleep 0.1
        
        update = queue.pop
        expect(update[:table]).to eq(:movies)
        expect(update[:id_col]).to eq(:movie_id)
        expect(update[:id_val]).to eq(1)
        expect(update[:data]).to eq({ poster_path: 'poster.jpg' })
      end
    end

    context 'when download fails' do
      before do
        allow(@tmdb_client).to receive(:download_image).and_return(nil)
      end

      it 'does not queue database update' do
        queue = importer.instance_variable_get(:@db_update_queue)
        
        importer.send(:enqueue_download, :movies, :poster_path, 1, '/poster.jpg', 'movies/1/poster.jpg')
        
        sleep 0.1
        
        expect(queue).to be_empty
      end
    end

    it 'handles nil api_path' do
      expect(thread_pool).not_to receive(:post)
      
      importer.send(:enqueue_download, :movies, :poster_path, 1, nil, 'movies/1/poster.jpg')
    end
  end

  describe '#enqueue_checksum_calculation' do
    let(:file_id) { 1 }
    let(:file_path) { File.join(test_directory, 'test.mkv') }
    let(:thread_pool) { importer.instance_variable_get(:@thread_pool) }

    before do
      File.write(file_path, 'test content')
    end

    it 'posts checksum task to thread pool' do
      expect(thread_pool).to receive(:post)
      
      importer.send(:enqueue_checksum_calculation, file_id, file_path)
    end

    it 'calculates SHA256 checksum' do
      queue = importer.instance_variable_get(:@db_update_queue)
      
      importer.send(:enqueue_checksum_calculation, file_id, file_path)
      
      sleep 0.1
      
      update = queue.pop
      expect(update[:table]).to eq(:movie_files)
      expect(update[:id_col]).to eq(:file_id)
      expect(update[:id_val]).to eq(file_id)
      expect(update[:data][:checksum_sha256]).to match(/^[a-f0-9]{64}$/)
    end

    context 'with large file' do
      before do
        # Create a 5MB file
        File.open(file_path, 'wb') { |f| f.write('x' * 5 * 1024 * 1024) }
      end

      it 'processes in chunks' do
        queue = importer.instance_variable_get(:@db_update_queue)
        
        importer.send(:enqueue_checksum_calculation, file_id, file_path)
        
        sleep 0.2
        
        update = queue.pop
        expect(update[:data][:checksum_sha256]).to be_present
      end
    end

    context 'with IO errors' do
      before do
        allow(File).to receive(:open).with(file_path, 'rb')
          .and_raise(Errno::EACCES.new('Permission denied'))
      end

      it 'logs warning and continues' do
        expect(PrettyLogger).to receive(:warn).with(/Failed to calculate checksum/)
        
        importer.send(:enqueue_checksum_calculation, file_id, file_path)
        
        sleep 0.1
      end
    end
  end

  describe '#process_db_updates' do
    let(:queue) { importer.instance_variable_get(:@db_update_queue) }
    let(:update_job) do
      {
        table: :movies,
        id_col: :movie_id,
        id_val: 1,
        data: { poster_path: 'test.jpg' }
      }
    end

    it 'processes updates from queue' do
      expect(@db_service).to receive(:update_record).with(**update_job)
      
      queue << update_job
      queue.close
      
      # Wait for processor thread
      sleep 0.1
    end

    it 'handles database errors gracefully' do
      allow(@db_service).to receive(:update_record)
        .and_raise(StandardError.new('DB Error'))
      expect(PrettyLogger).to receive(:error).with(/Unexpected error in DB updater/)
      
      queue << update_job
      queue.close
      
      sleep 0.1
    end
  end

  describe '#find_best_image' do
    let(:images) do
      [
        { 'file_path' => '/en.jpg', 'iso_639_1' => 'en' },
        { 'file_path' => '/fr.jpg', 'iso_639_1' => 'fr' },
        { 'file_path' => '/null.jpg', 'iso_639_1' => nil },
        { 'file_path' => '/de.jpg', 'iso_639_1' => 'de' }
      ]
    end

    it 'prefers exact language match' do
      result = importer.send(:find_best_image, images, 'fr')
      expect(result['iso_639_1']).to eq('fr')
    end

    it 'falls back to English' do
      result = importer.send(:find_best_image, images, 'es')
      expect(result['iso_639_1']).to eq('en')
    end

    it 'falls back to no language' do
      images_no_en = images.reject { |i| i['iso_639_1'] == 'en' }
      result = importer.send(:find_best_image, images_no_en, 'es')
      expect(result['iso_639_1']).to be_nil
    end

    it 'returns first image as last resort' do
      images_other = [{ 'file_path' => '/jp.jpg', 'iso_639_1' => 'jp' }]
      result = importer.send(:find_best_image, images_other, 'es')
      expect(result['iso_639_1']).to eq('jp')
    end

    it 'handles nil images array' do
      expect(importer.send(:find_best_image, nil, 'en')).to be_nil
    end

    it 'handles empty images array' do
      expect(importer.send(:find_best_image, [], 'en')).to be_nil
    end
  end

  describe '#present_search_choices' do
    let(:results) do
      [
        { 'title' => 'Movie 1', 'release_date' => '2020-01-01' },
        { 'title' => 'Movie 2', 'release_date' => '2021-01-01' },
        { 'title' => 'Movie 3', 'release_date' => nil }
      ]
    end

    before do
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)
    end

    it 'displays up to 8 choices' do
      large_results = (1..10).map { |i| { 'title' => "Movie #{i}", 'release_date' => '2020-01-01' } }
      
      expect($stdout).to receive(:puts).with(/\[8\]/).once
      expect($stdout).not_to receive(:puts).with(/\[9\]/)
      
      allow($stdin).to receive(:gets).and_return("1\n")
      
      importer.send(:present_search_choices, large_results, 'Query')
    end

    it 'handles user selecting a movie' do
      allow($stdin).to receive(:gets).and_return("2\n")
      
      result = importer.send(:present_search_choices, results, 'Query')
      expect(result).to eq(results[1])
    end

    it 'handles user choosing to skip (0)' do
      allow($stdin).to receive(:gets).and_return("0\n")
      
      result = importer.send(:present_search_choices, results, 'Query')
      expect(result).to be_nil
    end

    it 'handles invalid input with retry' do
      allow($stdin).to receive(:gets).and_return("invalid\n", "10\n", "1\n")
      
      expect($stdout).to receive(:puts).with(/Invalid choice/).twice
      
      result = importer.send(:present_search_choices, results, 'Query')
      expect(result).to eq(results[0])
    end

    it 'displays release year correctly' do
      expect($stdout).to receive(:puts).with(/Movie 1 \(2020\)/)
      expect($stdout).to receive(:puts).with(/Movie 3 \(\)/) # nil date
      
      allow($stdin).to receive(:gets).and_return("1\n")
      
      importer.send(:present_search_choices, results, 'Query')
    end
  end

  describe '#setup_media_directories' do
    it 'creates required directories' do
      expect(FileUtils).to receive(:mkdir_p)
        .with(File.join(TMDBMovieImporter::MEDIA_BASE_DIR, 'movies'))
      expect(FileUtils).to receive(:mkdir_p)
        .with(File.join(TMDBMovieImporter::MEDIA_BASE_DIR, 'people'))
      
      importer.send(:setup_media_directories)
    end
  end

  describe '#display_scan_summary' do
    before do
      allow($stdout).to receive(:puts)
    end

    it 'displays scan results' do
      expect(PrettyLogger).to receive(:info).with(/Scan Complete: Found 10 movie files/)
      expect(PrettyLogger).to receive(:success).with(/7 movies are already/)
      expect(PrettyLogger).to receive(:info).with(/3 new movies will be imported/)
      
      importer.send(:display_scan_summary, 10, 3)
    end

    it 'uses correct pluralization' do
      expect(PrettyLogger).to receive(:info).with(/1 new movie will be imported/)
      importer.send(:display_scan_summary, 1, 1)
      
      expect(PrettyLogger).to receive(:info).with(/2 new movies will be imported/)
      importer.send(:display_scan_summary, 2, 2)
    end
  end

  describe '#shutdown' do
    it 'shuts down thread pool' do
      pool = importer.instance_variable_get(:@thread_pool)
      expect(pool).to receive(:shutdown)
      expect(pool).to receive(:wait_for_termination).with(600)
      
      importer.shutdown
    end

    it 'closes database update queue' do
      queue = importer.instance_variable_get(:@db_update_queue)
      expect(queue).to receive(:close)
      
      importer.shutdown
    end

    it 'waits for updater thread' do
      thread = importer.instance_variable_get(:@db_updater_thread)
      expect(thread).to receive(:join)
      
      importer.shutdown
    end

    it 'closes database connection' do
      expect(@db_service).to receive(:close)
      
      importer.shutdown
    end

    it 'only runs once' do
      expect(@db_service).to receive(:close).once
      
      importer.shutdown
      importer.shutdown # Second call should do nothing
    end

    it 'logs completion' do
      expect(PrettyLogger).to receive(:info).with(/Waiting for background tasks/)
      expect(PrettyLogger).to receive(:success).with(/All background tasks finished/)
      
      importer.shutdown
    end
  end
end
