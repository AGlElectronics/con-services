#!/bin/sh
# MinIO is LOCAL / Docker Desktop development ONLY. NEVER use in production.
set -e
echo "Waiting for MinIO..."
until mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 1
done

for bucket in stash-data-dev den-data-dev events-data-dev hr-data-dev; do
  mc mb --ignore-existing "local/${bucket}"
  echo "bucket ready: ${bucket}"
done

echo "All module buckets ready (dev only)."
