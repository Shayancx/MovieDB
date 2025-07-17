#!/usr/bin/env ruby
require_relative 'config/environment'
require 'roda'
require 'json'

require_relative 'app/db'
require_relative 'app/services/movie_service'
require_relative 'app/services/person_service'
require_relative 'app/services/statistics_service'


class MovieExplorer < Roda
  plugin :json
  plugin :all_verbs
  plugin :halt
  plugin :render
  
  
  
  plugin :not_found do
    if request.path.start_with?('/api/')
      response.status = 404
      response['Content-Type'] = 'application/json'
      { error: 'API route not found' }
    else
      response['Content-Type'] = 'text/html'
      view('layout')
    end
  end
  
  plugin :error_handler do |e|
    warn "Error: #{e.message}"
    warn e.backtrace.join("\n")
    response.status = 500
    response['Content-Type'] = 'application/json'
    { error: 'Internal server error' }
  end

  plugin :default_headers,
    'Access-Control-Allow-Origin' => '*',
    'Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers' => 'Content-Type, Authorization'

  route do |r|
    r.on method: :options do
      response.status = 204
      ""
    end

    r.root do
      response['Content-Type'] = 'text/html'
      view('layout')
    end

    r.on 'api' do
      response['Content-Type'] = 'application/json'
      
      r.get 'movies' do
        MovieService.list
      end

      r.get 'movie', Integer do |movie_id|
        movie = MovieService.find(movie_id)
        r.halt(404, { error: 'Movie not found' }) unless movie
        movie
      end

      r.get 'genres' do
        MovieService.genres
      end

      r.get 'countries' do
        MovieService.countries
      end

      r.get 'languages' do
        MovieService.languages
      end

      r.get 'franchises' do
        MovieService.franchises
      end

      r.get 'person', Integer do |person_id|
        person = PersonService.find(person_id)
        r.halt(404, { error: 'Person not found' }) unless person
        person
      end

      r.get 'statistics' do
        StatisticsService.summary
      end
    end
  end
end
