#!/usr/bin/env ruby
require 'puma'
require 'puma/configuration'
require 'puma/launcher'
require 'rack'
require 'stringio'
require 'sequel'
require 'yaml'
require 'erb'

# Function to check database connection with correct config parsing
def check_database_connection
  begin
    # Load database configuration with ERB support for environment variables
    if File.exist?('database.yml')
      db_config = YAML.load(ERB.new(File.read('database.yml')).result)
    else
      return { status: "✗ Failed", error: "database.yml not found" }
    end
    
    # Build connection string with correct key names from your database.yml
    connection_params = {
      adapter: 'postgres',
      host: db_config['host'] || 'localhost',
      port: db_config['port'] || 5432,
      database: db_config['dbname'],  # Note: using 'dbname' as per your config
      user: db_config['user'],
      password: db_config['password'] || ''
    }
    
    # Try to connect
    db = Sequel.connect(connection_params)
    
    # Test the connection
    db.test_connection
    
    # Get PostgreSQL version
    pg_version = db.fetch("SELECT version()").first[:version].match(/PostgreSQL (\d+\.\d+(?:\.\d+)?)/)[1]
    
    # Get current time from database to verify connection
    db_time = db.fetch("SELECT current_timestamp as time").first[:time]
    
    # Get database name and size
    db_name = db_config['dbname']
    db_size = begin
      size_result = db.fetch("SELECT pg_size_pretty(pg_database_size(current_database())) as size").first
      size_result[:size]
    rescue
      "N/A"
    end
    
    # Count tables in public schema
    table_count = db.fetch("SELECT COUNT(*) as count FROM information_schema.tables WHERE table_schema = 'public'").first[:count]
    
    # Get connection count
    conn_count = db.fetch("SELECT count(*) as count FROM pg_stat_activity WHERE datname = current_database()").first[:count]
    
    db.disconnect
    
    {
      status: "✓ Connected",
      database: db_name,
      host: "#{db_config['host']}:#{db_config['port']}",
      user: db_config['user'],
      postgresql_version: pg_version,
      size: db_size,
      tables: table_count,
      active_connections: conn_count,
      server_time: db_time.strftime('%Y-%m-%d %H:%M:%S %Z')
    }
  rescue Sequel::DatabaseConnectionError => e
    {
      status: "✗ Connection Failed",
      error: e.message.split("\n").first,
      hint: "Check if PostgreSQL is running and user '#{db_config&.[]('user')}' has access to database '#{db_config&.[]('dbname')}'"
    }
  rescue => e
    {
      status: "✗ Failed",
      error: "#{e.class.name}: #{e.message}"
    }
  end
end

# Function to get system information
def get_system_info
  {
    memory: begin
      mem_kb = `ps -o rss= -p #{Process.pid}`.strip.to_i
      "#{(mem_kb / 1024.0).round(1)} MB"
    rescue
      "N/A"
    end,
    load_average: begin
      File.read('/proc/loadavg').split[0..2].join(', ')
    rescue
      "N/A"
    end,
    cpu_count: begin
      `nproc`.strip
    rescue
      "N/A"
    end
  }
end

# Function to check if required gems are loaded
def check_dependencies
  deps = []
  deps << "✓ Roda #{Roda::VERSION}" if defined?(Roda)
  deps << "✓ Sequel #{Sequel::VERSION}" if defined?(Sequel)
  deps << "✓ Rack #{Rack.release}" if defined?(Rack)
  deps << "✓ JSON #{JSON::VERSION}" if defined?(JSON)
  deps
end

# Clear screen for clean output (optional)
# print "\e[2J\e[H"

# Display enhanced startup message
puts "╔" + "═" * 78 + "╗"
puts "║" + " " * 25 + "► MovieExplorer Server ◄" + " " * 29 + "║"
puts "╚" + "═" * 78 + "╝"
puts ""

# Server Configuration
puts "▸ Server Configuration:"
puts "  Environment     : development"
puts "  Listening on    : tcp://0.0.0.0:3000"
puts "  View at         : http://localhost:3000"
puts "  Process ID      : #{Process.pid}"
puts "  Started at      : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
puts ""

# Runtime Information
puts "▸ Runtime Information:"
puts "  Ruby Version    : #{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_RELEASE_DATE} #{RUBY_PLATFORM})"
puts "  Puma Version    : #{Puma::Const::VERSION}"
puts "  Working Dir     : #{Dir.pwd}"
puts "  Config Files    : #{Dir.glob('*.{yml,ru}').join(', ')}"
puts ""

# System Information
sys_info = get_system_info
puts "▸ System Information:"
puts "  Memory Usage    : #{sys_info[:memory]}"
puts "  Load Average    : #{sys_info[:load_average]}"
puts "  CPU Cores       : #{sys_info[:cpu_count]}"
puts "  User            : #{ENV['USER']}"
puts ""

# Database Status
puts "▸ Database Status:"
db_info = check_database_connection
if db_info[:status].include?("Connected")
  puts "  Status          : #{db_info[:status]}"
  puts "  Database        : #{db_info[:database]}"
  puts "  Host            : #{db_info[:host]}"
  puts "  User            : #{db_info[:user]}"
  puts "  PostgreSQL      : v#{db_info[:postgresql_version]}"
  puts "  Database Size   : #{db_info[:size]}"
  puts "  Tables          : #{db_info[:tables]}"
  puts "  Connections     : #{db_info[:active_connections]}"
  puts "  Server Time     : #{db_info[:server_time]}"
else
  puts "  Status          : #{db_info[:status]}"
  puts "  Error           : #{db_info[:error]}"
  puts "  Hint            : #{db_info[:hint]}" if db_info[:hint]
end
puts ""

# Thread Configuration
puts "▸ Thread Configuration:"
puts "  Min Threads     : 0"
puts "  Max Threads     : 5"
puts "  Workers         : 1 (single mode)"
puts ""

# Dependencies loaded
puts "▸ Dependencies Loaded:"
check_dependencies.each { |dep| puts "  #{dep}" }
puts ""

puts "─" * 80
puts ">> Press Ctrl-C to stop"
puts "─" * 80
puts ""

# Create a null IO stream to silence Puma output
null_io = StringIO.new

# Load the Rack app from config.ru
app, options = Rack::Builder.parse_file('config.ru')

# Create Puma configuration
puma_config = Puma::Configuration.new do |config|
  config.app app
  config.bind 'tcp://0.0.0.0:3000'
  config.threads 0, 5
  config.environment 'development'
  config.quiet true  # Disable request logging
  config.log_requests false  # Puma 6.x way to disable request logging
end

# Create the launcher with custom log writer
launcher = Puma::Launcher.new(puma_config, log_writer: Puma::LogWriter.new(null_io, null_io))

# Store start time for uptime calculation
start_time = Time.now

# Trap signals for graceful shutdown
['INT', 'TERM'].each do |sig|
  Signal.trap(sig) do
    uptime = Time.now - start_time
    hours = (uptime / 3600).to_i
    minutes = ((uptime % 3600) / 60).to_i
    seconds = (uptime % 60).to_i
    
    puts "\n" + "─" * 80
    puts "► Shutting down gracefully..."
    puts "  Process ID      : #{Process.pid}"
    puts "  Uptime          : #{hours}h #{minutes}m #{seconds}s"
    puts "  Stopped at      : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    puts "─" * 80
    launcher.stop
    exit
  end
end

# Run the server
launcher.run