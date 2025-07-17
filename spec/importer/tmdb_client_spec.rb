# frozen_string_literal: true

require 'spec_helper'
require 'json'

ENV['TMDB_API_KEY'] ||= 'testkey'
require_relative '../../app/services/tmdb_client'

RSpec.describe TmdbClient do
  before do
    stub_request(:get, 'https://api.themoviedb.org/3/search/movie')
      .with(query: hash_including('api_key' => 'testkey', 'query' => 'Inception', 'year' => '2010'))
      .to_return(status: 200, body: { results: [{ id: 1,
                                                  title: 'Inception' }] }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'search_movie fetches results from TMDB' do
    client = TmdbClient.new
    results = client.search_movie('Inception', 2010)
    expect(results.first['title']).to eq('Inception')
  end

  it 'get_movie_details fetches movie details' do
    stub_request(:get, 'https://api.themoviedb.org/3/movie/1')
      .with(query: hash_including('api_key' => 'testkey', 'append_to_response' => 'credits,release_dates,images'))
      .to_return(status: 200, body: { id: 1,
                                      title: 'Inception' }.to_json, headers: { 'Content-Type' => 'application/json' })

    client = TmdbClient.new
    details = client.get_movie_details(1)
    expect(details['id']).to eq(1)
  end

  it 'downloads image and returns relative path' do
    client = TmdbClient.new
    allow(File).to receive(:exist?).and_return(false)
    allow(FileUtils).to receive(:mkdir_p)
    fake_io = StringIO.new('data')
    allow(URI).to receive(:open).and_yield(fake_io)
    allow(File).to receive(:open)
    path = client.download_image('/poster.jpg', 'movies/1/poster.jpg')
    expect(path).to eq('movies/1/poster.jpg')
  end

  it 'skips download when file already exists' do
    client = TmdbClient.new
    allow(File).to receive(:exist?).and_return(true)
    expect(URI).not_to receive(:open)
    path = client.download_image('/poster.jpg', 'movies/1/poster.jpg')
    expect(path).to eq('movies/1/poster.jpg')
  end

  it 'returns nil when download fails' do
    client = TmdbClient.new
    allow(File).to receive(:exist?).and_return(false)
    allow(FileUtils).to receive(:mkdir_p)
    allow(URI).to receive(:open).and_raise(StandardError.new('fail'))
    allow(PrettyLogger).to receive(:warn)
    expect(client.download_image('/poster.jpg', 'movies/1/poster.jpg')).to be_nil
  end

  describe '#make_api_request' do
    it 'retries when rate limited' do
      stub_request(:get, 'https://api.themoviedb.org/3/test')
        .with(query: hash_including('api_key' => 'testkey'))
        .to_return({ status: 429, headers: { 'Retry-After' => '0' } },
                   { status: 200, body: { ok: true }.to_json })

      client = TmdbClient.new
      allow(Kernel).to receive(:sleep)
      allow(PrettyLogger).to receive(:warn)
      result = client.send(:make_api_request, '/test')
      expect(result['ok']).to be true
    end

    it 'retries on network timeout and eventually succeeds' do
      stub_request(:get, 'https://api.themoviedb.org/3/test')
        .with(query: hash_including('api_key' => 'testkey'))
        .to_timeout
        .then
        .to_return(status: 200, body: { ok: true }.to_json)

      client = TmdbClient.new
      allow(Kernel).to receive(:sleep)
      allow(PrettyLogger).to receive(:warn)
      result = client.send(:make_api_request, '/test', {}, 1)
      expect(result['ok']).to be true
    end
  end
end
