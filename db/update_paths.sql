-- Update media paths to remove 'media/' prefix since we're now serving from /storage/media
-- Only run this if your paths currently start with 'media/'

-- Backup first!
CREATE TABLE movies_backup AS SELECT * FROM movies;
CREATE TABLE people_backup AS SELECT * FROM people;
CREATE TABLE movie_files_backup AS SELECT * FROM movie_files;

-- Update movie media paths (if they start with 'media/')
UPDATE movies 
SET poster_path = SUBSTRING(poster_path FROM 7)  -- Remove 'media/' prefix
WHERE poster_path LIKE 'media/%';

UPDATE movies 
SET backdrop_path = SUBSTRING(backdrop_path FROM 7)
WHERE backdrop_path LIKE 'media/%';

UPDATE movies 
SET logo_path = SUBSTRING(logo_path FROM 7)
WHERE logo_path LIKE 'media/%';

-- Update people headshot paths
UPDATE people 
SET headshot_path = SUBSTRING(headshot_path FROM 7)
WHERE headshot_path LIKE 'media/%';

-- Movie file paths might need updating depending on how they're stored
-- Check first with: SELECT file_path FROM movie_files LIMIT 10;
