-- Revocation and the freeze.
--
-- A letter can be pulled back out of the postbox right up until the carrier
-- takes it. After that it is gone, and nothing in the system can alter or
-- destroy it.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(18);

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-000000000002');

insert into public.profiles (id, display_name, home_lat, home_lng, timezone, country_code, region) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',  45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted');

-- Waiting in the postbox.
insert into public.letters (id, sender_id, recipient_id, body, state, written_at, collect_at) values
  ('e1111111-0000-4000-8000-00000000000a',
   'a0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002',
   'Still recallable.', 'awaiting_collection', now(), now() + interval '2 hours');

-- Already collected, three days out.
insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, deliver_at, delivery_date,
  recipient_tz, schedule_source
) values (
  'e2222222-0000-4000-8000-00000000000a',
  'a0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'Gone for good.', 'in_transit',
  now() - interval '1 day', now() - interval '1 day', now() - interval '1 day',
  (now() - interval '1 day')::date, 3, now() + interval '3 days', ((now() + interval '3 days') at time zone 'America/Los_Angeles')::date,
  'America/Los_Angeles', 'test-fixture'
);

-- Before collection ----------------------------------------------------------

set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- The mailbox read path runs as slowmail_reader, the role the SECURITY DEFINER
-- readers are owned by. authenticated has no privilege on letters at all now,
-- so asserting as authenticated would only ever prove "permission denied" and
-- would stay green if the policy itself were deleted.
set local role slowmail_reader;

set local role authenticated;
-- Executed as authenticated on purpose: these are client RPCs, and running
-- them under any other role would hide a missing grant exactly the way the
-- collection outage hid behind worker tests that ran as postgres.
select lives_ok(
  $$ select public.revoke_letter('e1111111-0000-4000-8000-00000000000a') $$,
  'the sender can recall a letter that has not been collected'
);
set local role slowmail_reader;

select is(
  (select state::text from public.letters where id = 'e1111111-0000-4000-8000-00000000000a'),
  'revoked',
  'a recalled letter is marked revoked'
);

select isnt(
  (select revoked_at from public.letters where id = 'e1111111-0000-4000-8000-00000000000a'),
  null,
  'a recalled letter records when it was pulled back'
);

-- After collection -----------------------------------------------------------

set local role authenticated;
-- Executed as authenticated on purpose: these are client RPCs, and running
-- them under any other role would hide a missing grant exactly the way the
-- collection outage hid behind worker tests that ran as postgres.
select throws_ok(
  $$ select public.revoke_letter('e2222222-0000-4000-8000-00000000000a') $$,
  'SM001',
  null,
  'the sender cannot recall a letter the carrier already took'
);
set local role slowmail_reader;

select is(
  (select state::text from public.letters where id = 'e2222222-0000-4000-8000-00000000000a'),
  'in_transit',
  'the failed recall left the letter in transit'
);

-- The client-level attempts below match no row, because RLS filters collected
-- letters out of the sender's UPDATE and DELETE policies. That is the first
-- line; the trigger assertions after `reset role` are the line that holds when
-- the first one is missing.
select lives_ok(
  $$ update public.letters set body = 'edited in flight'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'a client body edit on an in-transit letter matches no row'
);

select is(
  (select body from public.letters where id = 'e2222222-0000-4000-8000-00000000000a'),
  'Gone for good.',
  'the in-transit body is unchanged after the client attempt'
);

select lives_ok(
  $$ delete from public.letters where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'a client delete of an in-transit letter matches no row'
);

select is(
  (select count(*)::int from public.letters where id = 'e2222222-0000-4000-8000-00000000000a'),
  1,
  'the in-transit letter still exists after the client attempt'
);

-- Now with RLS out of the picture entirely.

reset role;

select throws_ok(
  $$ update public.letters set body = 'edited in flight'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM003',
  null,
  'the body of a collected letter cannot be changed by any role'
);

select throws_ok(
  $$ delete from public.letters where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM004',
  null,
  'a collected letter cannot be deleted by any role'
);

select throws_ok(
  $$ update public.letters set state = 'revoked'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM002',
  null,
  'in_transit cannot be walked back to revoked'
);

select throws_ok(
  $$ update public.letters set transit_days = 1, deliver_at = now()
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'the schedule of a collected letter is frozen'
);

select throws_ok(
  $$ update public.letters set recipient_id = 'a0000000-0000-4000-8000-000000000001'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'a letter cannot be readdressed'
);

select throws_ok(
  $$ update public.letters set state = 'delivered', delivered_at = now()
      where id = 'e1111111-0000-4000-8000-00000000000a' $$,
  'SM002',
  null,
  'a revoked letter cannot be resurrected as delivered'
);

-- The freeze is default-deny: every column that is not explicitly something a
-- letter learns after collection is immutable. These three cover the routing
-- inputs added after the first cut of the guard, which an enumerated freeze
-- list would have let through.
select throws_ok(
  $$ update public.letters set sender_region = 'CA'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'a sender who moves state cannot retime mail already in transit'
);

select throws_ok(
  $$ update public.letters set recipient_is_territory = true
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'the recipient territory flag is frozen at collection like every other routing input'
);

select throws_ok(
  $$ update public.letters set created_at = now() - interval '1 year'
      where id = 'e2222222-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'a column nobody thought to name is frozen too, because the guard denies by default'
);

select * from finish();
rollback;
