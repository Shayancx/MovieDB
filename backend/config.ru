require 'rack/static'
require_relative 'app'

# This middleware will serve files from the ../media directory
# for any requests that start with /media/
#
# The root path is now absolute to prevent directory issues.
use Rack::Static,
    urls: ['/media'], 
    root: File.expand_path('..', __dir__)

# Run the main application
run MovieExplorer