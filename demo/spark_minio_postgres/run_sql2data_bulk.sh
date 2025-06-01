#!/bin/bash
set -e

echo "🚀 Starting MinIO + PostgreSQL + Spark Delta Lake BULK demo..."

# Start Docker containers
echo "🧱 Starting services..."
docker compose up -d

# Wait for PostgreSQL to become ready
echo "⏳ Waiting for PostgreSQL to be ready..."
sleep 10

# Seed the PostgreSQL database with bulk data
echo "🌋 Seeding PostgreSQL with 1M rows..."
docker compose exec demo-db psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'demo'" | grep -q 1 || \
  docker compose exec demo-db psql -U postgres -c "CREATE DATABASE demo;"
docker compose exec demo-db psql -U postgres -d demo -c "CREATE TABLE IF NOT EXISTS sales (id SERIAL PRIMARY KEY, region TEXT, amount NUMERIC);"
docker compose exec demo-db psql -U postgres -d demo -c "
  INSERT INTO sales (region, amount)
  SELECT region, ROUND((random() * 1000)::numeric, 2)
  FROM generate_series(1, 1000000), (VALUES ('NA'), ('EMEA'), ('APAC')) AS r(region);
"

echo "🪣 Creating bucket if not exists..."
docker run --rm --network spark_minio_postgres_default \
  -e MC_HOST_local=http://minioadmin:minioadmin@minio:9000 \
  minio/mc mb -q --ignore-existing local/demo-bucket

# Export data to Parquet and upload to MinIO
echo "📤 Exporting sales table to Parquet in MinIO with sql2data..."
sql2data run \
  --db-url postgresql://postgres:postgres@localhost:5432/demo \
  --query "SELECT * FROM sales" \
  --output-file sales.parquet \
  --format parquet \
  --s3-bucket demo-bucket \
  --s3-key sales/sales.parquet \
  --s3-endpoint http://localhost:9000 \
  --s3-access-key minioadmin \
  --s3-secret-key minioadmin \
  --aws-region us-east-1

# Launch Spark job to process from MinIO
echo "✨ Launching Spark job to convert Parquet to Delta format..."
./run_spark_in_docker.sh

# Verify
echo "🔍 Verifying Delta output via fallback preview (DuckDB can't read Delta metadata)..."
duckdb -c "SELECT COUNT(*) FROM 'delta_output/*.parquet'"

echo "✅ Bulk demo complete."
