# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Set a dummy API key for tests
ENV['TMDB_API_KEY'] ||= 'test_key'

require_relative '../../app/services/tmdb_client'

RSpec.describe TmdbClient do
  let(:client) { described_class.new }
  let(:api_base_url) { 'https://api.themoviedb.org/3' }
  let(:image_base_url) { 'https://image.tmdb.org/t/p/original' }

  # Mock the MEDIA_BASE_DIR constant for tests
  before do
    stub_const('TmdbClient::MEDIA_BASE_DIR', Dir.mktmpdir)
    allow(PrettyLogger).to receive(:info)
    allow(PrettyLogger).to receive(:warn)
    allow(PrettyLogger).to receive(:error)
    allow(PrettyLogger).to receive(:debug)
    # Mock sleep to avoid delays in tests
    allow(client).to receive(:sleep)
  end

  after do
    FileUtils.rm_rf(TmdbClient::MEDIA_BASE_DIR)
  end

  describe '#search_movie' do
    it 'returns search results on success' do
      stub_request(:get, /#{api_base_url}\/search\/movie/)
        .to_return(status: 200, body: { results: [{ 'title' => 'Inception' }] }.to_json)

      results = client.search_movie('Inception', 2010)
      expect(results).to be_an(Array)
      expect(results.first['title']).to eq('Inception')
    end

    it 'returns an empty array on API error' do
      stub_request(:get, /#{api_base_url}\/search\/movie/).to_return(status: 500)
      expect(client.search_movie('Inception', 2010)).to eq([])
    end
  end

  describe '#get_movie_details' do
    it 'returns movie details on success' do
      stub_request(:get, /#{api_base_url}\/movie\/123/)
        .to_return(status: 200, body: { 'id' => 123, 'title' => 'Test Movie' }.to_json)

      details = client.get_movie_details(123)
      expect(details['id']).to eq(123)
    end

    it 'returns nil if movie not found (404)' do
      stub_request(:get, /#{api_base_url}\/movie\/999/).to_return(status: 404)
      details = client.get_movie_details(999)
      expect(details).to be_nil
    end
  end

  describe '#download_image' do
    let(:api_path) { '/poster.jpg' }
    let(:save_path) { 'movies/1/poster.jpg' }
    let(:full_save_path) { File.join(TmdbClient::MEDIA_BASE_DIR, save_path) }
    let(:source_url) { "#{image_base_url}#{api_path}" }

    it 'returns nil if api_path is blank' do
      expect(client.download_image(nil, save_path)).to be_nil
      expect(client.download_image('  ', save_path)).to be_nil
    end

    it 'skips download if file already exists' do
      allow(File).to receive(:exist?).with(full_save_path).and_return(true)
      expect(URI).not_to receive(:open)
      expect(client.download_image(api_path, save_path)).to eq(save_path)
    end

    it 'downloads and saves the image' do
      FileUtils.mkdir_p(File.dirname(full_save_path))
      stub_request(:get, source_url).to_return(status: 200, body: 'image data')

      result = client.download_image(api_path, save_path)

      expect(result).to eq(save_path)
      expect(File.read(full_save_path)).to eq('image data')
    end

    it 'creates the destination directory if it does not exist' do
      stub_request(:get, source_url).to_return(status: 200, body: 'image data')
      parent_dir = File.dirname(full_save_path)
      expect(FileUtils).to receive(:mkdir_p).with(parent_dir).and_call_original

      client.download_image(api_path, save_path)
    end

    it 'returns nil on download failure' do
      stub_request(:get, source_url).to_return(status: 404)
      result = client.download_image(api_path, save_path)
      expect(result).to be_nil
    end

    it 'returns nil if directory is not writable' do
      parent_dir = File.dirname(full_save_path)
      allow(FileUtils).to receive(:mkdir_p).with(parent_dir)
      allow(File).to receive(:writable?).with(parent_dir).and_return(false)

      expect(client.download_image(api_path, save_path)).to be_nil
      expect(PrettyLogger).to have_received(:error).with("Directory not writable: #{parent_dir}")
    end
  end

  describe 'private methods' do
    describe '#retry_with_backoff' do
      it 'retries on specified errors and succeeds' do
        attempts = 0
        expect(client).to receive(:sleep).with(2).ordered
        expect(client).to receive(:sleep).with(4).ordered

        result = client.send(:retry_with_backoff) do
          attempts += 1
          raise Net::ReadTimeout if attempts < 3
          'success'
        end

        expect(result).to eq('success')
      end

      it 're-raises error after max attempts' do
        attempts = 0
        expect do
          client.send(:retry_with_backoff) do
            attempts += 1
            raise Net::OpenTimeout
          end
        end.to raise_error(Net::OpenTimeout)
        expect(attempts).to eq(3)
      end
    end

    describe '#handle_api_response' do
      it 'parses JSON for successful responses' do
        response = Net::HTTPSuccess.new('1.1', '200', 'OK')
        allow(response).to receive(:body).and_return('{"status":"ok"}')
        expect(client.send(:handle_api_response, response)).to eq({ 'status' => 'ok' })
      end

      it 'handles rate limiting by raising a custom error' do
        response = Net::HTTPTooManyRequests.new('1.1', '429', 'Too Many Requests')
        allow(response).to receive(:[]).with('Retry-After').and_return('5')
        expect(client).to receive(:sleep).with(5)
        expect { client.send(:handle_api_response, response) }.to raise_error(TmdbClient::RateLimitError)
      end

      it 'returns nil for other client/server errors' do
        response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
        allow(response).to receive(:uri).and_return('http://example.com')
        expect(client.send(:handle_api_response, response)).to be_nil
      end

      it 'returns nil on JSON parsing error' do
        response = Net::HTTPSuccess.new('1.1', '200', 'OK')
        allow(response).to receive(:body).and_return('invalid json')
        expect(client.send(:handle_api_response, response)).to be_nil
        expect(PrettyLogger).to have_received(:error).with(/Failed to parse JSON/)
      end
    end
  end
end