require 'rack/static'
require_relative 'app'

# Updated paths for public directory
use Rack::Static, 
  urls: ["/css", "/js", "/index.html"],
  root: File.expand_path('public', __dir__)

# Updated path for media files
use Rack::Static, 
  urls: ["/media"],
  root: File.expand_path('storage', __dir__)

run MovieExplorer