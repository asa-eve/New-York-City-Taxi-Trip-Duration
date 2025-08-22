#!/bin/bash

echo "🛠️ Starting SQL Data Processing container..."
docker-compose -p sql_data -f docker/sql_data_processing/docker-compose.yml up -d

echo "⏳ Waiting for PostgreSQL to be ready..."
until docker exec pg_geo pg_isready -U postgres -d geo_db; do
    sleep 2
    echo "Still waiting..."
done

echo "🚀 Running SQL transformation script..."
docker exec -i pg_geo psql -U postgres -d geo_db <<EOF
\set ON_ERROR_STOP on
\set ECHO all
\i /docker-entrypoint-initdb.d/data_transform.sql
EOF

echo "✅ SQL transformation complete."

echo "🧼 Cleaning up SQL Data Processing container..."
docker-compose -p sql_data -f docker/sql_data_processing/docker-compose.yml down

echo "🫧 All cleaned up!"
