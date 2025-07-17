require 'rack/static'
require_relative 'app'

use Rack::Static, urls: ["/index.html", "/style.css", "/alpine.min.js"], root: __dir__
use Rack::Static, urls: ["/media"], root: __dir__

run MovieExplorer
