-- Executed by the postgres image's docker-entrypoint-initdb.d hook, which runs only when the
-- data directory is empty (i.e. on the very first start of a fresh volume).
CREATE DATABASE auth_prj;
CREATE DATABASE payments_prj;
