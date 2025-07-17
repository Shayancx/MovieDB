# MovieDB

A small Roda/Puma application for managing a personal movie collection.

## Requirements

- Ruby 3.4 or newer
- PostgreSQL
- Bundler (`gem install bundler`)

## Setup

1. Install the Ruby gems:

```bash
bundle install
```

2. Configure the database connection. Copy `config/database.yml` and adjust it for your PostgreSQL credentials. The importer and server read this file or the following environment variables:
`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.

3. Create the database and load the schema:

```bash
createdb MovieDB
psql -U <your_user> -d MovieDB -f db/schema.sql
```

Refer to `db/schema.sql` for table definitions and to `config/database.yml` for connection parameters.

4. Set the `TMDB_API_KEY` environment variable before running the importer. Optional variables include `MAX_BG_THREADS` and `DEBUG`.

## Usage

### Starting the server

```bash
bin/server
```

This runs a Puma server on http://localhost:3000.

### Importing movies

```bash
TMDB_API_KEY=your_key bin/import /path/to/movies
```

The importer scans the given directory, fetches metadata from TMDB and stores it in the database.

## Development

You can modify the application routes in `app.rb` and static assets in the `public/` directory.

## Testing

Install dependencies and run the test suite with Rake:

```bash
bundle install
bundle exec rake
```
