DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'intercom') THEN
    CREATE ROLE intercom LOGIN PASSWORD 'intercom';
  END IF;
END
$$;

SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = 'intercom')
  THEN 'exists' ELSE 'missing' END AS intercom_db;
