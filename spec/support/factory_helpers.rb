# frozen_string_literal: true

module FactoryHelpers
  def build_movie_details
    {
      'id' => 123,
      'title' => 'Test Movie',
      'original_title' => 'Test Movie Original',
      'release_date' => '2023-01-01',
      'overview' => 'A test movie description',
      'runtime' => 120,
      'vote_average' => 8.5,
      'imdb_id' => 'tt1234567',
      'poster_path' => '/poster.jpg',
      'backdrop_path' => '/backdrop.jpg',
      'belongs_to_collection' => { 'id' => 1, 'name' => 'Test Collection' },
      'genres' => [
        { 'id' => 28, 'name' => 'Action' },
        { 'id' => 12, 'name' => 'Adventure' }
      ],
      'production_countries' => [
        { 'iso_3166_1' => 'US', 'name' => 'United States' }
      ],
      'spoken_languages' => [
        { 'iso_639_1' => 'en', 'english_name' => 'English' }
      ],
      'credits' => {
        'cast' => [
          { 'id' => 1, 'name' => 'Actor One', 'character' => 'Hero', 'order' => 0 },
          { 'id' => 2, 'name' => 'Actor Two', 'character' => 'Villain', 'order' => 1 }
        ],
        'crew' => [
          { 'id' => 3, 'name' => 'Director One', 'job' => 'Director' },
          { 'id' => 4, 'name' => 'Writer One', 'job' => 'Screenplay' }
        ]
      },
      'images' => {
        'posters' => [
          { 'file_path' => '/poster1.jpg', 'iso_639_1' => 'en' },
          { 'file_path' => '/poster2.jpg', 'iso_639_1' => 'fr' }
        ],
        'backdrops' => [
          { 'file_path' => '/backdrop1.jpg', 'iso_639_1' => 'en' }
        ],
        'logos' => [
          { 'file_path' => '/logo1.png', 'iso_639_1' => 'en' }
        ]
      }
    }
  end

  def build_mediainfo_data
    {
      'media' => {
        'track' => [
          {
            '@type' => 'General',
            'Format' => 'Matroska',
            'Duration' => '7200',
            'FileSize' => '1073741824'
          },
          {
            '@type' => 'Video',
            'Format' => 'H.265',
            'BitRate' => '1500000',
            'FrameRate' => '23.976',
            'DisplayAspectRatio' => '2.39:1',
            'Width' => '3840',
            'Height' => '2160'
          },
          {
            '@type' => 'Audio',
            'Format' => 'DTS',
            'BitRate' => '768000',
            'Channels' => '6'
          }
        ]
      }
    }
  end
end

RSpec.configure do |config|
  config.include FactoryHelpers
end
