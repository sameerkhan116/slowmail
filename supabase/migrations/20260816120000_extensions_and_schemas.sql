-- Extensions and the internal schema.
--
-- `slowmail` holds machinery the postal jobs need but that no client may ever
-- reach. PostgREST only exposes the schemas listed in config.toml
-- (`public`, `graphql_public`), so nothing in `slowmail` has an HTTP surface.

create extension if not exists pg_cron;
create extension if not exists pg_net;

create schema if not exists slowmail;

revoke all on schema slowmail from public;
revoke all on schema slowmail from anon, authenticated;
grant usage on schema slowmail to postgres, service_role;

-- Anything created later in `slowmail` is private by default.
alter default privileges in schema slowmail revoke all on functions from public, anon, authenticated;
alter default privileges in schema slowmail revoke all on tables from public, anon, authenticated;
