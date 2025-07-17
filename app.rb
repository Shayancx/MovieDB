#!/usr/bin/env ruby
# frozen_string_literal: true

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

  def image_url(item, type = 'poster')
    return '' unless item

    path = case type
           when 'person' then item[:headshot_path]
           when 'backdrop' then item[:backdrop_path]
           else item[:poster_path]
           end
    placeholder = case type
                  when 'person' then 'https://placehold.co/200x300/0a0a0a/1a1a1a?text=NO+PHOTO'
                  when 'backdrop' then 'https://placehold.co/1280x720/0a0a0a/1a1a1a?text=NO+BACKDROP'
                  else 'https://placehold.co/500x750/0a0a0a/1a1a1a?text=NO+POSTER'
                  end
    return placeholder unless path

    "/media/#{path}"
  end

  def format_date(date)
    return 'N/A' unless date

    Date.parse(date.to_s).strftime('%B %d, %Y')
  end

  def format_runtime(min)
    return 'N/A' unless min

    hours = min / 60
    mins  = min % 60
    "#{hours}h #{mins}m"
  end

  def query_with_page(page)
    Rack::Utils.build_query(request.GET.merge('page' => page))
  end

  plugin :not_found do
    if request.path.start_with?('/api/')
      response.status = 404
      response['Content-Type'] = 'application/json'
      { error: 'API route not found' }
    else
      response['Content-Type'] = 'text/html'
      view('not_found')
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
      ''
    end

    r.root do
      r.redirect '/movies'
    end

    r.get 'movies' do
      filters = {
        search: r.params['search'],
        genre: r.params['genre'],
        country: r.params['country'],
        language: r.params['language'],
        franchise: r.params['franchise'],
        year: r.params['year'],
        sort_by: r.params['sort_by'],
        sort_order: r.params['sort_order']
      }
      all_movies = MovieService.filtered(filters)
      @total = all_movies.size
      @page = (r.params['page'] || '1').to_i
      @movies_per_page = 24
      @movies = all_movies.slice((@page - 1) * @movies_per_page, @movies_per_page) || []
      @total_pages = (@total / @movies_per_page.to_f).ceil

      @genres = MovieService.genres
      @countries = MovieService.countries
      @languages = MovieService.languages
      @franchises = MovieService.franchises
      @years = MovieService.years

      view('index')
    end

    r.get 'movie', Integer do |movie_id|
      @movie = MovieService.find(movie_id)
      r.halt(404, 'Movie not found') unless @movie
      view('movie')
    end

    r.get 'statistics' do
      @statistics = StatisticsService.summary
      view('statistics')
    end

    r.on 'api' do
      response['Content-Type'] = 'application/json'

      r.get 'movies' do
        MovieService.filtered(r.params)
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
