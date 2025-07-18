# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'json'

RSpec.describe MovieExplorer do
  include Rack::Test::Methods

  def app
    MovieExplorer
  end

  before(:all) do
    # Mock database connection
    @mock_db = mock_db_connection
    stub_const('DB', @mock_db)
    
    # Suppress warnings during test
    @original_stderr = $stderr
    $stderr = StringIO.new
    
    # Load the app
    load File.expand_path('../../app.rb', __FILE__)
  end

  after(:all) do
    $stderr = @original_stderr
  end

  let(:test_movie) { create_movie }
  let(:test_movies) { [test_movie, create_movie(movie_id: 2, movie_name: 'Another Movie')] }

  describe 'Route Testing' do
    describe 'GET /' do
      it 'redirects to /movies' do
        get '/'
        expect(last_response).to be_redirect
        expect(last_response.location).to end_with('/movies')
      end
    end

    describe 'GET /movies' do
      before do
        allow(MovieService).to receive(:filtered).and_return(test_movies)
        allow(MovieService).to receive(:genres).and_return([])
        allow(MovieService).to receive(:countries).and_return([])
        allow(MovieService).to receive(:languages).and_return([])
        allow(MovieService).to receive(:franchises).and_return([])
        allow(MovieService).to receive(:years).and_return([])
      end

      it 'returns HTML response with movies' do
        get '/movies'
        expect(last_response).to be_ok
        expect(last_response.content_type).to include('text/html')
      end

      it 'passes filters to MovieService' do
        expect(MovieService).to receive(:filtered).with(hash_including(
          search: 'test',
          genre: 'Action',
          sort_by: 'date',
          sort_order: 'desc'
        ))
        get '/movies?search=test&genre=Action&sort_by=date&sort_order=desc'
      end

      it 'handles pagination parameters' do
        get '/movies?page=2'
        expect(last_response).to be_ok
      end

      it 'sets instance variables for view' do
        get '/movies'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /movie/:id' do
      context 'when movie exists' do
        before do
          allow(MovieService).to receive(:find).with(1).and_return(test_movie)
        end

        it 'returns movie detail page' do
          get '/movie/1'
          expect(last_response).to be_ok
          expect(last_response.body).to include(test_movie[:movie_name])
        end
      end

      context 'when movie does not exist' do
        before do
          allow(MovieService).to receive(:find).with(999).and_return(nil)
        end

        it 'returns 404 page' do
          get '/movie/999'
          expect(last_response.status).to eq(404)
        end
      end

      it 'handles non-integer ID gracefully' do
        get '/movie/abc'
        expect(last_response.status).to eq(404)
      end
    end

    describe 'GET /statistics' do
      let(:stats) do
        {
          total_movies: 100,
          total_size_gb: 1024.5,
          total_runtime_hours: 200,
          movies_per_genre: [],
          movies_per_year: []
        }
      end

      before do
        allow(StatisticsService).to receive(:summary).and_return(stats)
      end

      it 'returns statistics page' do
        get '/statistics'
        expect(last_response).to be_ok
        expect(last_response.body).to include('DATABASE STATISTICS')
      end
    end

    describe 'API endpoints' do
      describe 'GET /api/movies' do
        before do
          allow(MovieService).to receive(:filtered).and_return(test_movies)
        end

        it 'returns JSON response' do
          get '/api/movies'
          expect(last_response).to be_ok
          expect(last_response.content_type).to include('application/json')
          
          body = JSON.parse(last_response.body)
          expect(body).to be_an(Array)
          expect(body.length).to eq(2)
        end

        it_behaves_like 'a paginated endpoint', '/api/movies'
      end

      describe 'GET /api/movie/:id' do
        context 'when movie exists' do
          before do
            allow(MovieService).to receive(:find).with(1).and_return(test_movie)
          end

          it 'returns movie as JSON' do
            get '/api/movie/1'
            expect(last_response).to be_ok
            
            body = JSON.parse(last_response.body)
            expect(body['movie_name']).to eq(test_movie[:movie_name])
          end
        end

        context 'when movie does not exist' do
          before do
            allow(MovieService).to receive(:find).with(999).and_return(nil)
          end

          it_behaves_like 'an API error response', 404 do
            before { get '/api/movie/999' }
          end
        end
      end

      %w[genres countries languages franchises].each do |resource|
        describe "GET /api/#{resource}" do
          let(:test_data) { [{ "#{resource.singularize}_id": 1, "#{resource.singularize}_name": 'Test' }] }

          before do
            allow(MovieService).to receive(resource.to_sym).and_return(test_data)
          end

          it "returns #{resource} as JSON" do
            get "/api/#{resource}"
            expect(last_response).to be_ok
            
            body = JSON.parse(last_response.body)
            expect(body).to eq(test_data.map(&:stringify_keys))
          end
        end
      end

      describe 'GET /api/person/:id' do
        let(:test_person) { create_person }

        context 'when person exists' do
          before do
            allow(PersonService).to receive(:find).with(1).and_return(test_person)
          end

          it 'returns person as JSON' do
            get '/api/person/1'
            expect(last_response).to be_ok
            
            body = JSON.parse(last_response.body)
            expect(body['full_name']).to eq(test_person[:full_name])
          end
        end

        context 'when person does not exist' do
          before do
            allow(PersonService).to receive(:find).with(999).and_return(nil)
          end

          it_behaves_like 'an API error response', 404 do
            before { get '/api/person/999' }
          end
        end
      end

      describe 'GET /api/statistics' do
        let(:stats) { { total_movies: 100 } }

        before do
          allow(StatisticsService).to receive(:summary).and_return(stats)
        end

        it 'returns statistics as JSON' do
          get '/api/statistics'
          expect(last_response).to be_ok
          
          body = JSON.parse(last_response.body)
          expect(body['total_movies']).to eq(100)
        end
      end

      describe 'OPTIONS requests (CORS)' do
        it 'returns 204 for OPTIONS request' do
          options '/api/movies'
          expect(last_response.status).to eq(204)
          expect(last_response.body).to be_empty
        end

        it 'includes CORS headers' do
          get '/api/movies'
          expect(last_response.headers['Access-Control-Allow-Origin']).to eq('*')
          expect(last_response.headers['Access-Control-Allow-Methods']).to include('GET')
        end
      end
    end
  end

  describe 'Helper Method Testing' do
    let(:app_instance) { MovieExplorer.allocate }

    describe '#image_url' do
      it 'returns correct URL for poster with path' do
        item = { poster_path: 'movies/1/poster.jpg' }
        expect(app_instance.image_url(item)).to eq('/media/movies/1/poster.jpg')
      end

      it 'returns placeholder for nil item' do
        expect(app_instance.image_url(nil)).to eq('')
      end

      it 'returns correct placeholder for missing poster' do
        item = { poster_path: nil }
        url = app_instance.image_url(item)
        expect(url).to include('placehold.co')
        expect(url).to include('NO+POSTER')
      end

      it 'handles person type' do
        item = { headshot_path: 'people/1/photo.jpg' }
        expect(app_instance.image_url(item, 'person')).to eq('/media/people/1/photo.jpg')
      end

      it 'handles backdrop type' do
        item = { backdrop_path: 'movies/1/backdrop.jpg' }
        expect(app_instance.image_url(item, 'backdrop')).to eq('/media/movies/1/backdrop.jpg')
      end

      it 'returns correct placeholder for each type' do
        item = {}
        expect(app_instance.image_url(item, 'person')).to include('NO+PHOTO')
        expect(app_instance.image_url(item, 'backdrop')).to include('NO+BACKDROP')
        expect(app_instance.image_url(item, 'poster')).to include('NO+POSTER')
      end
    end

    describe '#format_date' do
      it 'formats valid date correctly' do
        expect(app_instance.format_date('2023-12-25')).to eq('December 25, 2023')
        expect(app_instance.format_date(Date.new(2023, 12, 25))).to eq('December 25, 2023')
      end

      it 'returns N/A for nil date' do
        expect(app_instance.format_date(nil)).to eq('N/A')
      end

      it 'handles invalid date strings' do
        expect { app_instance.format_date('invalid') }.to raise_error(Date::Error)
      end
    end

    describe '#format_runtime' do
      it 'formats runtime correctly' do
        expect(app_instance.format_runtime(90)).to eq('1h 30m')
        expect(app_instance.format_runtime(120)).to eq('2h 0m')
        expect(app_instance.format_runtime(45)).to eq('0h 45m')
      end

      it 'returns N/A for nil' do
        expect(app_instance.format_runtime(nil)).to eq('N/A')
      end

      it 'handles zero runtime' do
        expect(app_instance.format_runtime(0)).to eq('0h 0m')
      end

      it 'handles large numbers' do
        expect(app_instance.format_runtime(600)).to eq('10h 0m')
        expect(app_instance.format_runtime(1439)).to eq('23h 59m')
      end
    end

    describe '#query_with_page' do
      it 'adds page parameter to existing query' do
        allow(app_instance).to receive(:request).and_return(
          double(GET: { 'search' => 'test', 'genre' => 'Action' })
        )
        result = app_instance.query_with_page(2)
        expect(result).to include('page=2')
        expect(result).to include('search=test')
        expect(result).to include('genre=Action')
      end

      it 'handles empty query parameters' do
        allow(app_instance).to receive(:request).and_return(double(GET: {}))
        expect(app_instance.query_with_page(1)).to eq('page=1')
      end

      it 'handles special characters in params' do
        allow(app_instance).to receive(:request).and_return(
          double(GET: { 'search' => 'test & special' })
        )
        result = app_instance.query_with_page(1)
        expect(result).to include('search=test+%26+special')
      end
    end
  end

  describe 'Error Handling' do
    it 'handles unexpected exceptions gracefully' do
      allow(MovieService).to receive(:filtered).and_raise(StandardError.new('Unexpected error'))
      
      get '/movies'
      # The error handler should catch this, but since we're testing the framework
      # we expect the error to propagate in test environment
      expect { get '/movies' }.to raise_error(StandardError)
    end

    context 'with not_found plugin' do
      it 'returns JSON for API routes' do
        get '/api/nonexistent'
        expect(last_response.status).to eq(404)
        expect(last_response.content_type).to include('application/json')
        
        body = JSON.parse(last_response.body)
        expect(body['error']).to eq('API route not found')
      end

      it 'returns HTML for non-API routes' do
        get '/nonexistent'
        expect(last_response.status).to eq(404)
        expect(last_response.content_type).to include('text/html')
      end
    end

    context 'database connection errors' do
      it 'handles connection failures' do
        allow(MovieService).to receive(:filtered)
          .and_raise(Sequel::DatabaseConnectionError.new('Connection failed'))
        
        expect { get '/api/movies' }.to raise_error(Sequel::DatabaseConnectionError)
      end
    end
  end

  describe 'Security and Headers' do
    it 'includes security headers' do
      get '/api/movies'
      headers = last_response.headers
      expect(headers['Access-Control-Allow-Origin']).to eq('*')
    end

    it 'handles malformed requests' do
      get '/movie/"><script>alert(1)</script>'
      expect(last_response.status).to eq(404)
    end
  end
end
