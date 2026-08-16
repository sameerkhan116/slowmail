-- Closing the side doors.
--
-- RLS covers SELECT, count(*) and RETURNING because they all run through the
-- same policy predicate. The vectors that do not are handled here.

-- 1. Realtime. postgres_changes evaluates RLS per subscriber for the new row,
--    but the old-row image on UPDATE and DELETE is not policy-filtered, and an
--    INSERT event is itself proof that a row appeared. Either would announce a
--    letter days before the carrier does, so letters are never published.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime' and puballtables) then
    raise exception 'supabase_realtime publishes all tables; letters would be broadcast before delivery';
  end if;

  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'letters'
  ) then
    alter publication supabase_realtime drop table public.letters;
  end if;
end;
$$;

-- 1b. This check only runs when migrations run, and publishing a table is a
--     one-click operation in the Supabase dashboard. A runtime block is not
--     available: PostgreSQL 17 fires no event trigger for CREATE PUBLICATION or
--     ALTER PUBLICATION (verified on 17.6 with an unfiltered ddl_command_start
--     and ddl_command_end trigger, which logged CREATE TABLE and stayed silent
--     for both publication commands), so there is nowhere to hook.
--
--     What does hold at runtime is the replica identity below. letters is
--     REPLICA IDENTITY NOTHING, so while the table is published every UPDATE
--     against it fails with "cannot update table \"letters\" because it does not
--     have a replica identity and publishes updates". Collection and delivery
--     both stop within one cron interval. That is a loud failure rather than a
--     silent leak, but it does not cover INSERT, which needs no replica
--     identity. The remaining line of defence there is RLS: Realtime evaluates
--     the subscriber's SELECT policy against the new row before sending it, and
--     an undelivered letter fails that policy. supabase/tests/realtime proves
--     both halves empirically.

-- 2. Views. A view runs with its owner's privileges unless it is a security
--    invoker view, which would hand any reader the owner's view of letters.
--    Nothing here defines such a view; this guard makes adding one later fail
--    the migration instead of quietly opening a door.
create or replace function slowmail.assert_no_leaky_views()
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_bad text;
begin
  select string_agg(c.relname, ', ')
    into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('v', 'm')
    and n.nspname = 'public'
    and exists (
      select 1
      from pg_depend d
      join pg_rewrite r on r.oid = d.objid
      where d.refobjid = 'public.letters'::regclass
        and d.classid = 'pg_rewrite'::regclass
        and r.ev_class = c.oid
    )
    and coalesce((
      select option_value from pg_options_to_table(c.reloptions)
      where option_name = 'security_invoker'
    ), 'false') <> 'true';

  if v_bad is not null then
    raise exception 'relations over public.letters bypass RLS (need security_invoker=true): %', v_bad;
  end if;
end;
$$;

revoke all on function slowmail.assert_no_leaky_views() from public;

select slowmail.assert_no_leaky_views();

-- 3. Foreign keys. A constraint violation message names the offending key, so a
--    client-writable table referencing letters(id) would turn insert errors
--    into an existence oracle. Nothing outside the letters table itself may
--    reference it.
do $$
declare
  v_bad text;
begin
  select string_agg(conrelid::regclass::text, ', ')
    into v_bad
  from pg_constraint
  where contype = 'f'
    and confrelid = 'public.letters'::regclass
    and conrelid <> 'public.letters'::regclass;

  if v_bad is not null then
    raise exception 'tables referencing public.letters can leak letter ids through constraint errors: %', v_bad;
  end if;
end;
$$;

-- 4. Query plans. PostgREST can be asked to return EXPLAIN output, and row
--    estimates are drawn from statistics that RLS does not filter. The Data API
--    must never expose plans in production.
comment on table public.letters is
  'A letter and its schedule. Recipient visibility is gated on deliver_at <= now() by RLS, not by the client. Never publish this table to Realtime, never expose it through a non-invoker view, and keep db-plan-enabled off on the Data API.';
