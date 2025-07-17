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
end
