require 'spec_helper'
require 'json'
require 'rack/test'

RSpec.describe 'MovieExplorer API' do
  include Rack::Test::Methods

  before(:all) do
    RSpec::Mocks.with_temporary_scope do
      db_stub = Class.new do
        def extension(*) = nil
        def test_connection = nil
      end
      @mock_db = db_stub.new
      allow(Sequel).to receive(:connect).and_return(@mock_db)
      load File.expand_path('../../app.rb', __FILE__)
      stub_const('DB', @mock_db)
    end
  end

  def app
    MovieExplorer
  end

  let(:db) { DB }

  describe 'GET /api/movies' do
    it 'returns movies from the database' do
      allow(MovieService).to receive(:filtered)
        .and_return([{ movie_id: 1, movie_name: 'Test Movie' }])

      get '/api/movies'

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body.first['movie_name']).to eq('Test Movie')
    end
  end

  describe 'GET /api/movie/:id when not found' do
    it 'returns 404' do
      allow(MovieService).to receive(:find).and_return(nil)

      get '/api/movie/1'

      expect(last_response.status).to eq(404)
      body = JSON.parse(last_response.body)
      expect(body['error']).to eq('Movie not found')
    end
  end
end
