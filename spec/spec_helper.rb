require 'rspec'
require 'rack/test'
require 'webmock/rspec'
require 'sequel'

ENV['RACK_ENV'] ||= 'test'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.order = :random
end
