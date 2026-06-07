SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    :'terminus_db_user',
    :'terminus_db_password'
)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'terminus_db_user')
\gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN PASSWORD %L',
    :'terminus_db_user',
    :'terminus_db_password'
)
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = :'terminus_db_user')
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'terminus_db_name',
    :'terminus_db_user'
)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'terminus_db_name')
\gexec

SELECT format(
    'GRANT ALL PRIVILEGES ON DATABASE %I TO %I',
    :'terminus_db_name',
    :'terminus_db_user'
)
\gexec
