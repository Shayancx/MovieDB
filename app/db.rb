# frozen_string_literal: true

require 'sequel'
require 'yaml'

begin
  db_config_path = File.join(__dir__, '..', 'config', 'database.yml')
  db_config = YAML.load_file(db_config_path) if File.exist?(db_config_path)

  DB = Sequel.connect(
    adapter: 'postgres',
    host: db_config&.[]('host') || ENV['DB_HOST'] || 'localhost',
    port: db_config&.[]('port') || ENV['DB_PORT'] || 5432,
    database: db_config&.[]('dbname') || ENV['DB_NAME'] || 'MovieDB',
    user: db_config&.[]('user') || ENV['DB_USER'] || 'shayan',
    password: db_config&.[]('password') || ENV['DB_PASSWORD'] || ''
  )
  DB.extension :pg_array
  DB.test_connection
rescue Sequel::DatabaseConnectionError => e
  warn '=' * 80
  warn 'DATABASE CONNECTION FAILED'
  warn '=' * 80
  warn 'Could not connect to the PostgreSQL database.'
  warn 'Please check your configuration.'
  warn "Error details: #{e.message}"
  warn '=' * 80
  exit 1
end
