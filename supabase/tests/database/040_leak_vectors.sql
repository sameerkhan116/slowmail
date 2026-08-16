-- The side doors.
--
-- The recipient SELECT policy is only worth anything if every other route to
-- the same information is closed. Each assertion here corresponds to a way row
-- existence normally escapes a policy.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(19);

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000003');

insert into public.profiles (id, display_name, home_lat, home_lng, timezone, country_code, region) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',  45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR'),
  ('c0000000-0000-4000-8000-000000000003', 'Cyd', 41.8781,  -87.6298, 'America/Chicago',     'US', 'IL');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted');

insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, deliver_at,
  recipient_tz, schedule_source
) values (
  'f1111111-0000-4000-8000-00000000000a',
  'a0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'Secret until Thursday.', 'in_transit',
  now() - interval '1 day', now() - interval '1 day', now() - interval '1 day',
  (now() - interval '1 day')::date, 4, now() + interval '4 days',
  'America/Los_Angeles', 'test-fixture'
);

-- Structural checks ----------------------------------------------------------

select ok(
  (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.letters'::regclass),
  'row level security is enabled and forced on letters, so even the owner is subject to it'
);

-- Realtime broadcasts row existence. postgres_changes filters the new row by
-- RLS but not the old-row image on UPDATE and DELETE, and an INSERT event is
-- itself a signal. letters must never be published.
select is(
  (select count(*)::int from pg_publication_tables
    where schemaname = 'public' and tablename = 'letters'),
  0,
  'letters is not a member of any publication, so Realtime cannot announce one'
);

select is(
  (select relreplident from pg_class where oid = 'public.letters'::regclass),
  'n'::"char",
  'letters has REPLICA IDENTITY NOTHING, so publishing it later fails loudly instead of leaking'
);

-- A view runs with its owner's rights unless it is security_invoker, which
-- would hand every reader the owner's unfiltered view of the table.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     join pg_depend d on d.refobjid = 'public.letters'::regclass
                     and d.classid = 'pg_rewrite'::regclass
     join pg_rewrite r on r.oid = d.objid and r.ev_class = c.oid
    where c.relkind in ('v', 'm')
      and n.nspname in ('public', 'graphql_public')
      and coalesce((select option_value from pg_options_to_table(c.reloptions)
                     where option_name = 'security_invoker'), 'false') <> 'true'),
  0,
  'no API-visible view over letters bypasses RLS'
);

-- A constraint violation names the key that collided, so a client-writable
-- table pointing at letters(id) would answer "does this letter exist".
select is(
  (select count(*)::int from pg_constraint
    where contype = 'f' and confrelid = 'public.letters'::regclass
      and conrelid <> 'public.letters'::regclass),
  0,
  'nothing outside letters holds a foreign key to it, so no constraint error can confirm a letter id'
);

select ok(
  not has_table_privilege('anon', 'public.letters', 'select'),
  'anonymous callers have no privilege on letters at all'
);

select ok(
  not has_column_privilege('authenticated', 'public.letters', 'deliver_at', 'insert')
  and not has_column_privilege('authenticated', 'public.letters', 'deliver_at', 'update'),
  'deliver_at is not writable by a client on insert or update'
);

select ok(
  not has_column_privilege('authenticated', 'public.letters', 'state', 'update')
  and not has_column_privilege('authenticated', 'public.letters', 'collected_at', 'update')
  and not has_column_privilege('authenticated', 'public.letters', 'delivered_at', 'update'),
  'no schedule column is client-writable'
);

select ok(
  not has_schema_privilege('authenticated', 'slowmail', 'usage'),
  'the internal schema is unreachable from a client, and is not exposed by the Data API'
);

select ok(
  not has_function_privilege('authenticated', 'public.claim_collection_batch(integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.apply_collection(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.claim_push_batch(integer)', 'execute'),
  'the postal worker functions are not callable by a client'
);

-- Behavioural checks, as the recipient ----------------------------------------

set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
-- The mailbox read path runs as slowmail_reader, the role the SECURITY DEFINER
-- readers are owned by. authenticated has no privilege on letters at all now,
-- so asserting as authenticated would only ever prove "permission denied" and
-- would stay green if the policy itself were deleted.
set local role slowmail_reader;

select is(
  (select count(*)::int from public.letters),
  0,
  'count(*) does not see the in-transit letter'
);

select is(
  (select max(deliver_at) from public.letters),
  null,
  'an aggregate over the schedule returns nothing, not a delivery date'
);

select ok(
  not exists (select 1 from public.letters),
  'EXISTS cannot be used to test for the letter'
);

-- RETURNING is evaluated through the SELECT policy, so a write that matches
-- nothing also returns nothing.
select is_empty(
  $$ update public.letters set body = 'probe' returning id, body $$,
  'UPDATE ... RETURNING leaks nothing'
);

select is_empty(
  $$ delete from public.letters returning id, sender_id $$,
  'DELETE ... RETURNING leaks nothing'
);

-- Run on the path a client actually has: mailbox() plus the profiles table.
-- Asserting this as a role with no privilege on letters would pass on a
-- permission error rather than on the rule holding.
reset role;
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.mailbox() m join public.profiles p on p.id = m.sender_id),
  0,
  'joining out to the sender profile does not resurrect the row'
);

reset role;
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role slowmail_reader;

-- The correspondent helper answers "is this person my correspondent", never
-- "are these two people connected", so it cannot be used to map strangers.
reset role;
set local request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003","role":"authenticated"}';
set local role authenticated;

select ok(
  not public.is_accepted_correspondent('a0000000-0000-4000-8000-000000000001'),
  'an outsider cannot see a link they are not part of'
);

select is(
  (select count(*)::int from public.correspondents),
  0,
  'an outsider sees no correspondent rows'
);

select is(
  (select count(*)::int from public.profiles),
  1,
  'an outsider sees only their own profile'
);

reset role;
select * from finish();
rollback;
