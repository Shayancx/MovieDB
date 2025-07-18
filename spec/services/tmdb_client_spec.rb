# frozen_string_literal: true

require 'spec_helper'
require 'json'

ENV['TMDB_API_KEY'] ||= 'testkey'
require_relative '../../app/services/tmdb_client'

RSpec.describe TMDBClient do
  let(:client) { described_class.new }
  let(:api_base) { 'https://api.themoviedb.org/3' }

  describe '#initialize' do
    it 'sets up HTTP connection with SSL' do
      expect(client.instance_variable_get(:@http).use_ssl?).to be true
    end

    it 'sets appropriate timeouts' do
      http = client.instance_variable_get(:@http)
      expect(http.open_timeout).to eq(10)
      expect(http.read_timeout).to eq(30)
    end
  end

  describe '#search_movie' do
    context 'with successful search' do
      before do
        stub_request(:get, "#{api_base}/search/movie")
          .with(query: hash_including('api_key' => 'testkey', 'query' => 'Inception', 'year' => '2010'))
          .to_return(
            status: 200,
            body: { 
              results: [
                { id: 1, title: 'Inception', release_date: '2010-07-16' },
                { id: 2, title: 'Inception: The Cobol Job', release_date: '2010-12-07' }
              ] 
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns search results' do
        results = client.search_movie('Inception', 2010)
        expect(results).to be_an(Array)
        expect(results.first['title']).to eq('Inception')
      end
    end

    context 'with empty results' do
      before do
        stub_request(:get, "#{api_base}/search/movie")
          .with(query: hash_including('query' => 'NonexistentMovie'))
          .to_return(
            status: 200,
            body: { results: [] }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns empty array' do
        results = client.search_movie('NonexistentMovie', nil)
        expect(results).to eq([])
      end
    end

    context 'without year parameter' do
      before do
        stub_request(:get, "#{api_base}/search/movie")
          .with(query: hash_excluding('year'))
          .to_return(
            status: 200,
            body: { results: [{ id: 1, title: 'Test' }] }.to_json
          )
      end

      it 'omits year from query' do
        client.search_movie('Test', nil)
        expect(WebMock).to have_requested(:get, "#{api_base}/search/movie")
          .with(query: hash_excluding('year'))
      end
    end

    context 'with API errors' do
      it 'handles 404 errors' do
        stub_request(:get, "#{api_base}/search/movie")
          .to_return(status: 404)
        
        expect(PrettyLogger).to receive(:warn)
        results = client.search_movie('Test', nil)
        expect(results).to eq([])
      end

      it 'handles 500 errors' do
        stub_request(:get, "#{api_base}/search/movie")
          .to_return(status: 500)
        
        expect(PrettyLogger).to receive(:warn)
        results = client.search_movie('Test', nil)
        expect(results).to eq([])
      end
    end

    context 'with malformed response' do
      before do
        stub_request(:get, "#{api_base}/search/movie")
          .to_return(
            status: 200,
            body: 'invalid json',
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns empty array' do
        expect(PrettyLogger).to receive(:error)
        results = client.search_movie('Test', nil)
        expect(results).to eq([])
      end
    end
  end

  describe '#get_movie_details' do
    let(:movie_details) { build_movie_details }

    context 'with successful fetch' do
      before do
        stub_request(:get, "#{api_base}/movie/123")
          .with(query: hash_including(
            'api_key' => 'testkey',
            'append_to_response' => 'credits,release_dates,images'
          ))
          .to_return(
            status: 200,
            body: movie_details.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns movie details with appended data' do
        details = client.get_movie_details(123)
        expect(details['id']).to eq(123)
        expect(details).to have_key('credits')
        expect(details).to have_key('images')
      end
    end

    context 'when movie not found' do
      before do
        stub_request(:get, "#{api_base}/movie/999")
          .to_return(status: 404)
      end

      it 'returns nil' do
        expect(PrettyLogger).to receive(:warn)
        expect(client.get_movie_details(999)).to be_nil
      end
    end

    context 'with rate limiting' do
      before do
        stub_request(:get, "#{api_base}/movie/123")
          .to_return(
            { status: 429, headers: { 'Retry-After' => '1' } },
            { status: 200, body: movie_details.to_json }
          )
      end

      it 'retries after waiting' do
        expect(PrettyLogger).to receive(:warn).with(/Rate limited/)
        expect(client).to receive(:sleep).with(1)
        
        details = client.get_movie_details(123)
        expect(details['id']).to eq(123)
      end
    end

    context 'with network timeouts' do
      before do
        stub_request(:get, "#{api_base}/movie/123")
          .to_timeout
          .then
          .to_return(status: 200, body: movie_details.to_json)
      end

      it 'retries on timeout' do
        expect(PrettyLogger).to receive(:warn).with(/Network error/)
        expect(client).to receive(:sleep)
        
        details = client.get_movie_details(123)
        expect(details['id']).to eq(123)
      end
    end
  end

  describe '#download_image' do
    let(:image_url) { 'https://image.tmdb.org/t/p/original/poster.jpg' }
    let(:save_path) { 'movies/1/poster.jpg' }
    let(:full_path) { File.join(TMDBClient::MEDIA_BASE_DIR, save_path) }

    context 'with successful download' do
      before do
        allow(File).to receive(:exist?).with(full_path).and_return(false)
        allow(FileUtils).to receive(:mkdir_p)
        
        fake_image = StringIO.new('fake image data')
        allow(URI).to receive(:open).with(image_url).and_yield(fake_image)
        
        fake_file = StringIO.new
        allow(File).to receive(:open).with(full_path, 'wb').and_yield(fake_file)
      end

      it 'downloads and saves image' do
        expect(PrettyLogger).to receive(:debug).with(/Downloaded image/)
        
        path = client.download_image('/poster.jpg', save_path)
        expect(path).to eq(save_path)
      end

      it 'creates directory if needed' do
        expect(FileUtils).to receive(:mkdir_p).with(File.dirname(full_path))
        
        client.download_image('/poster.jpg', save_path)
      end
    end

    context 'when file already exists' do
      before do
        allow(File).to receive(:exist?).with(full_path).and_return(true)
      end

      it 'skips download and returns path' do
        expect(URI).not_to receive(:open)
        
        path = client.download_image('/poster.jpg', save_path)
        expect(path).to eq(save_path)
      end
    end

    context 'with download failure' do
      before do
        allow(File).to receive(:exist?).and_return(false)
        allow(FileUtils).to receive(:mkdir_p)
        allow(URI).to receive(:open).and_raise(OpenURI::HTTPError.new('404', nil))
      end

      it 'returns nil and logs warning' do
        expect(PrettyLogger).to receive(:warn).with(/Failed to download/)
        
        path = client.download_image('/poster.jpg', save_path)
        expect(path).to be_nil
      end
    end

    context 'with network errors' do
      before do
        allow(File).to receive(:exist?).and_return(false)
        allow(FileUtils).to receive(:mkdir_p)
      end

      it 'retries and eventually fails' do
        allow(URI).to receive(:open).and_raise(Net::ReadTimeout)
        expect(client).to receive(:sleep).at_least(:twice)
        expect(PrettyLogger).to receive(:warn)
        
        expect(client.download_image('/poster.jpg', save_path)).to be_nil
      end
    end

    context 'with invalid URLs' do
      it 'handles nil path' do
        expect(client.download_image(nil, save_path)).to be_nil
      end

      it 'handles empty path' do
        expect(client.download_image('', save_path)).to be_nil
      end
    end

    it 'creates correct full URL' do
      allow(File).to receive(:exist?).and_return(false)
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:open)
      
      expect(URI).to receive(:open).with(image_url)
      
      client.download_image('/poster.jpg', save_path)
    end
  end

  describe 'private methods' do
    describe '#make_api_request' do
      context 'with successful request' do
        before do
          stub_request(:get, "#{api_base}/test")
            .with(query: hash_including('api_key' => 'testkey'))
            .to_return(status: 200, body: { success: true }.to_json)
        end

        it 'returns parsed JSON' do
          result = client.send(:make_api_request, '/test')
          expect(result['success']).to be true
        end

        it 'includes additional parameters' do
          stub_request(:get, "#{api_base}/test")
            .with(query: hash_including('api_key' => 'testkey', 'param' => 'value'))
            .to_return(status: 200, body: {}.to_json)
          
          client.send(:make_api_request, '/test', { param: 'value' })
          
          expect(WebMock).to have_requested(:get, "#{api_base}/test")
            .with(query: hash_including('param' => 'value'))
        end
      end

      context 'with rate limiting' do
        before do
          stub_request(:get, "#{api_base}/test")
            .to_return(
              { status: 429, headers: { 'Retry-After' => '2' } },
              { status: 200, body: { success: true }.to_json }
            )
        end

        it 'waits and retries' do
          expect(PrettyLogger).to receive(:warn).with(/Rate limited/)
          expect(client).to receive(:sleep).with(2)
          
          result = client.send(:make_api_request, '/test')
          expect(result['success']).to be true
        end

        it 'uses default wait time if Retry-After missing' do
          stub_request(:get, "#{api_base}/test")
            .to_return(
              { status: 429 },
              { status: 200, body: { success: true }.to_json }
            )
          
          expect(client).to receive(:sleep).with(10)
          
          client.send(:make_api_request, '/test')
        end
      end

      context 'with network errors' do
        it 'retries on timeout with backoff' do
          stub_request(:get, "#{api_base}/test")
            .to_timeout
            .then
            .to_timeout
            .then
            .to_return(status: 200, body: { success: true }.to_json)
          
          expect(PrettyLogger).to receive(:warn).twice
          expect(client).to receive(:sleep).with(4).ordered
          expect(client).to receive(:sleep).with(3).ordered
          
          result = client.send(:make_api_request, '/test')
          expect(result['success']).to be true
        end

        it 'gives up after max retries' do
          stub_request(:get, "#{api_base}/test").to_timeout
          
          expect(PrettyLogger).to receive(:warn).exactly(3).times
          expect(PrettyLogger).to receive(:error)
          
          result = client.send(:make_api_request, '/test')
          expect(result).to be_nil
        end

        it 'handles connection reset' do
          stub_request(:get, "#{api_base}/test")
            .to_raise(Errno::ECONNRESET)
            .then
            .to_return(status: 200, body: { success: true }.to_json)
          
          expect(PrettyLogger).to receive(:warn)
          expect(client).to receive(:sleep)
          
          result = client.send(:make_api_request, '/test')
          expect(result['success']).to be true
        end
      end

      context 'with HTTP errors' do
        it 'logs and returns nil for 404' do
          stub_request(:get, "#{api_base}/test").to_return(status: 404)
          
          expect(PrettyLogger).to receive(:warn).with(/404 Not Found/)
          
          result = client.send(:make_api_request, '/test')
          expect(result).to be_nil
        end

        it 'logs and returns nil for 500' do
          stub_request(:get, "#{api_base}/test")
            .to_return(status: 500, body: 'Internal Server Error')
          
          expect(PrettyLogger).to receive(:warn).with(/500/)
          
          result = client.send(:make_api_request, '/test')
          expect(result).to be_nil
        end
      end
    end

    describe '#retry_with_backoff' do
      it 'executes block successfully' do
        result = client.send(:retry_with_backoff) { 'success' }
        expect(result).to eq('success')
      end

      it 'retries on timeout' do
        attempts = 0
        expect(client).to receive(:sleep).twice
        
        result = client.send(:retry_with_backoff) do
          attempts += 1
          raise Net::OpenTimeout if attempts < 3
          'success'
        end
        
        expect(result).to eq('success')
      end

      it 'retries on HTTP error' do
        attempts = 0
        expect(client).to receive(:sleep).once
        
        result = client.send(:retry_with_backoff) do
          attempts += 1
          raise OpenURI::HTTPError.new('500', nil) if attempts < 2
          'success'
        end
        
        expect(result).to eq('success')
      end

      it 're-raises after max attempts' do
        expect(client).to receive(:sleep).twice
        
        expect {
          client.send(:retry_with_backoff) { raise Net::ReadTimeout }
        }.to raise_error(Net::ReadTimeout)
      end

      it 'uses decreasing sleep times' do
        attempts = 0
        
        expect(client).to receive(:sleep).with(2).ordered
        expect(client).to receive(:sleep).with(1).ordered
        
        client.send(:retry_with_backoff) do
          attempts += 1
          raise Net::ReadTimeout if attempts < 3
          'success'
        end
      end
    end
  end
end
