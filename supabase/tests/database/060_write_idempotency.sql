-- Posting the same letter twice because the first reply went missing.
--
-- The client cannot tell "the request never arrived" from "the reply never came
-- back", so it must be free to retry. These assert that retrying is safe: the
-- same client key returns the letter already posted, and a different key is
-- still a different letter.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(9);

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-000000000002');

insert into public.profiles (id, display_name, home_lat, home_lng, timezone, country_code, region) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',  45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted');

set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- A key is not optional. An optional one is a key a client can forget to send,
-- and the omission is invisible until the day a reply is lost.
select throws_ok(
  $$ select public.write_letter(
       'b0000000-0000-4000-8000-000000000002', 'no key', null) $$,
  'SM006',
  'a client key is required to post',
  'posting without a client key is refused'
);

-- The first attempt.
create temporary table posted as
select (public.write_letter(
  'b0000000-0000-4000-8000-000000000002',
  'Only once',
  'd0000000-0000-4000-8000-00000000000a')).*;

select is(
  (select count(*)::int from posted),
  1,
  'the first attempt posts one letter'
);

select isnt(
  (select id from posted),
  null,
  'the first attempt returns the letter it posted'
);

-- The retry: same key, same words, as a client repeating a request whose reply
-- it never saw.
create temporary table retried as
select (public.write_letter(
  'b0000000-0000-4000-8000-000000000002',
  'Only once',
  'd0000000-0000-4000-8000-00000000000a')).*;

select is(
  (select id from retried),
  (select id from posted),
  'retrying with the same key returns the letter already posted'
);

-- The assertion that actually matters. Comparing the two returned ids would
-- stay green if the retry inserted a second letter and happened to return the
-- first; this counts what is really in the table.
select is(
  (select count(*)::int from public.outbox()),
  1,
  'the sender has posted one letter, not two'
);

select is(
  (select state from retried),
  (select state from posted),
  'the retry reports the same state, not a fresh unposted one'
);

-- A letter genuinely written twice is still two letters, or idempotency has
-- turned into "you may only ever send this once".
create temporary table second as
select (public.write_letter(
  'b0000000-0000-4000-8000-000000000002',
  'Only once',
  'd0000000-0000-4000-8000-00000000000b')).*;

select isnt(
  (select id from second),
  (select id from posted),
  'a different key is a different letter even with identical words'
);

select is(
  (select count(*)::int from public.outbox()),
  2,
  'writing a second letter deliberately still produces two'
);

-- One sender's key must not reach another sender's letter, or the key becomes a
-- way to ask whether somebody else has posted.
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';

insert into public.correspondents (requester_id, addressee_id, status) values
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', 'accepted')
on conflict do nothing;

select isnt(
  (select (public.write_letter(
     'a0000000-0000-4000-8000-000000000001',
     'mine',
     'd0000000-0000-4000-8000-00000000000a')).id),
  (select id from posted),
  'the same key used by a different sender writes a new letter, not theirs'
);

select * from finish();
rollback;
