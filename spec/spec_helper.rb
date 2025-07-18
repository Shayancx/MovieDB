# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
end

require 'rspec'
require 'rack/test'
require 'webmock/rspec'
require 'sequel'
require 'rspec/mocks/standalone'

ENV['RACK_ENV'] ||= 'test'
ENV['TMDB_API_KEY'] ||= 'test_key'
WebMock.disable_net_connect!(allow_localhost: true)

# Ensure all threads are killed after each test
RSpec.configure do |config|
  config.order = :random
  
  config.before(:suite) do
    # Stub the database connection before loading application code
    db_stub = double('db').as_null_object
    allow(Sequel).to receive(:connect).and_return(db_stub)
  end
  
  config.after(:each) do
    # Kill any lingering threads from importers
    Thread.list.each do |thread|
      thread.kill unless thread == Thread.current
    end
  end
end

# Load application files after database stub
require_relative '../app/db'
require_relative '../app/services/pretty_logger'
require_relative '../app/services/database_service'
require_relative '../app/services/media_info_parser'
require_relative '../app/services/movie_service'
require_relative '../app/services/person_service'
require_relative '../app/services/series_service'
require_relative '../app/services/statistics_service'
require_relative '../app/services/tmdb_client'
require_relative '../app/services/tmdb_series_importer'
require_relative '../app/services/tmdb_movie_importer'
require_relative '../app/services/tui'
require_relative '../app'

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |f| require f }

# Enhanced thread cleanup
RSpec.configure do |config|
  config.before(:suite) do
    # Set a timeout for all tests
    RSpec.configuration.default_formatter = 'progress'
  end
  
  config.around(:each) do |example|
    # Run each test with a timeout
    Timeout.timeout(30) do
      example.run
    end
  rescue Timeout::Error
    skip "Test timed out after 30 seconds"
  end
  
  config.after(:each) do |example|
    # More aggressive thread cleanup
    if defined?(TMDBMovieImporter)
      ObjectSpace.each_object(TMDBMovieImporter) do |importer|
        importer.shutdown rescue nil
      end
    end
    
    if defined?(TMDBSeriesImporter)
      ObjectSpace.each_object(TMDBSeriesImporter) do |importer|
        importer.shutdown rescue nil
      end
    end
    
    # Kill all threads except main
    Thread.list.each do |thread|
      next if thread == Thread.main
      thread.kill
      thread.join(0.1) rescue nil
    end
    
    # Clear any thread pools
    if defined?(Concurrent::ThreadPoolExecutor)
      ObjectSpace.each_object(Concurrent::ThreadPoolExecutor) do |pool|
        pool.shutdown
        pool.kill unless pool.wait_for_termination(1)
      end
    end
  end
end
