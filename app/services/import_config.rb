# frozen_string_literal: true

module ImportConfig
  TMDB_API_BASE_URL = 'https://api.themoviedb.org/3'
  TMDB_IMAGE_BASE_URL = 'https://image.tmdb.org/t/p/original'
  MEDIA_BASE_DIR = File.expand_path('../../storage/media', __dir__)
  MAX_BG_THREADS = ENV.fetch('MAX_BG_THREADS', 5).to_i
  TMDB_API_KEY = ENV.fetch('TMDB_API_KEY') do
    puts "\n[\e[31mFATAL\e[0m] TMDB_API_KEY environment variable not set."
    puts 'Please set it before running the script:'
    puts '  export TMDB_API_KEY="your_key_here"'
    exit 1
  end
end
