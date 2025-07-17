# frozen_string_literal: true

# Puma configuration for MovieDB

quiet

# Load the Rack application
rackup File.expand_path('../config.ru', __dir__)

# Bind to all interfaces on port 3000
bind 'tcp://0.0.0.0:3000'

# Thread pool configuration
min_threads = ENV.fetch('PUMA_MIN_THREADS', 0).to_i
max_threads = ENV.fetch('PUMA_MAX_THREADS', 5).to_i
threads min_threads, max_threads

# Worker processes (0 for single mode)
workers ENV.fetch('WEB_CONCURRENCY', 0).to_i

# Environment
environment ENV.fetch('RACK_ENV', 'development')

preload_app!

plugin :tmp_restart
