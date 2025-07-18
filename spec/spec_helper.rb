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

# ----------------------------------------------------------------------
# Stub the database connection before loading application code
db_stub = double('db').as_null_object
allow(Sequel).to receive(:connect).and_return(db_stub)

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

RSpec.configure do |config|
  config.order = :random
end
