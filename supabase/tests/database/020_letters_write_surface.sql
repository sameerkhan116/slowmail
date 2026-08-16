-- What a client is allowed to write, and what the database refuses outright.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(20);

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000003');

insert into public.profiles (id, display_name, home_lat, home_lng, timezone, country_code, region) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',  45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR'),
  ('c0000000-0000-4000-8000-000000000003', 'Cyd', 41.8781,  -87.6298, 'America/Chicago',     'US', 'IL');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted'),
  ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003', 'pending');

set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- The mailbox read path runs as slowmail_reader, the role the SECURITY DEFINER
-- readers are owned by. authenticated has no privilege on letters at all now,
-- so asserting as authenticated would only ever prove "permission denied" and
-- would stay green if the policy itself were deleted.
set local role slowmail_reader;

-- Schedule columns are not in the client's INSERT grant, so this is rejected by
-- the privilege system before any policy or trigger is consulted.
select throws_ok(
  $$ insert into public.letters (recipient_id, body, deliver_at)
     values ('b0000000-0000-4000-8000-000000000002', 'now please', now()) $$,
  '42501',
  'permission denied for table letters',
  'a client setting deliver_at = now() on insert is rejected by column privileges'
);

select throws_ok(
  $$ insert into public.letters (recipient_id, body, state)
     values ('b0000000-0000-4000-8000-000000000002', 'shortcut', 'delivered') $$,
  '42501',
  'permission denied for table letters',
  'a client cannot choose the state of a letter it inserts'
);

select throws_ok(
  $$ insert into public.letters (recipient_id, body, collected_at)
     values ('b0000000-0000-4000-8000-000000000002', 'shortcut', now()) $$,
  '42501',
  'permission denied for table letters',
  'a client cannot set collected_at'
);

select throws_ok(
  $$ update public.letters set state = 'delivered' $$,
  '42501',
  'permission denied for table letters',
  'a client cannot update state on any letter'
);

-- A pending request is not an accepted correspondent.
select throws_ok(
  $$ insert into public.letters (recipient_id, body)
     values ('c0000000-0000-4000-8000-000000000003', 'hello stranger') $$,
  '42501',
  'new row violates row-level security policy for table "letters"',
  'writing to someone who has not accepted is blocked by the insert policy, not by a privilege'
);

-- id is deliberately absent from the client's INSERT grant, so a guessed id
-- cannot be turned into an existence oracle through a primary key violation.
select throws_ok(
  $$ insert into public.letters (id, recipient_id, body)
     values (gen_random_uuid(), 'b0000000-0000-4000-8000-000000000002', 'probe') $$,
  '42501',
  'permission denied for table letters',
  'a client cannot choose a letter id, so it cannot probe for one'
);

select lives_ok(
  $$ insert into public.letters (recipient_id, body)
     values ('b0000000-0000-4000-8000-000000000002', 'Draft one.') $$,
  'writing to an accepted correspondent is allowed'
);

select is(
  (select state::text from public.letters where body like 'Draft %'),
  'draft',
  'a client insert lands as a draft with no schedule'
);

select is(
  (select sender_id from public.letters where body like 'Draft %'),
  slowmail.current_user_id(),
  'sender_id is taken from the JWT, not from the request body'
);

select lives_ok(
  $$ update public.letters set body = 'Draft two.'
      where body like 'Draft %' $$,
  'a draft body is editable by its writer'
);

-- Posting -------------------------------------------------------------------

set local role authenticated;
-- Executed as authenticated on purpose: these are client RPCs, and running
-- them under any other role would hide a missing grant exactly the way the
-- collection outage hid behind worker tests that ran as postgres.
select lives_ok(
  $$ select public.post_letter((select id from public.outbox() where body = 'Draft two.')) $$,
  'the writer can post their own draft'
);
set local role slowmail_reader;

select is(
  (select state::text from public.letters where body like 'Draft %'),
  'awaiting_collection',
  'a posted letter waits for collection'
);

-- The SQL cutoff is only a lower bound on the real collection instant, but it
-- must always be a 17:00 in the sender's own zone.
select is(
  (select (collect_at at time zone 'America/New_York')::time
     from public.letters where body like 'Draft %'),
  time '17:00',
  'the candidate collection cutoff is 17:00 in the senders own timezone'
);

-- At client level the row simply falls outside the UPDATE policy, so the
-- statement matches nothing rather than erroring. The seal itself is a trigger,
-- which only fires once a row is actually matched, so it is asserted separately
-- against a role that RLS does not filter.
select lives_ok(
  $$ update public.letters set body = 'sneaky' where body like 'Draft %' $$,
  'a client update of a posted letter raises nothing, because the policy matches no row'
);

select is(
  (select body from public.letters where body like 'Draft %'),
  'Draft two.',
  'a client cannot change the body of a posted letter'
);

reset role;

select throws_ok(
  $$ update public.letters set body = 'sneaky' where body like 'Draft %' $$,
  'SM003',
  null,
  'the body is sealed once the letter is posted, even for a role RLS does not filter'
);

-- Impersonation ---------------------------------------------------------------

set local request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003","role":"authenticated"}';
set local role slowmail_reader;

select throws_ok(
  $$ insert into public.letters (recipient_id, body)
     values ('b0000000-0000-4000-8000-000000000002', 'from someone elses hand') $$,
  '42501',
  'new row violates row-level security policy for table "letters"',
  'a third party cannot post to a pair they are not part of'
);

reset role;

-- A letter with nowhere to go ------------------------------------------------

-- post_letter freezes the routing inputs onto the envelope, and a profile with
-- no coordinates freezes nulls. The collection worker cannot route those, and no
-- later profile edit can repair the letter, because repairing a frozen envelope
-- is exactly the recomputation the snapshot exists to prevent -- so the letter
-- sits in the postbox for good. Refusing the post is the last moment at which
-- the profile is still the source of truth and the sender is still there to be
-- told.
insert into auth.users (id) values ('d0000000-0000-4000-8000-000000000004');
insert into public.profiles (id, display_name, timezone, country_code, region)
values ('d0000000-0000-4000-8000-000000000004', 'Dee', 'America/Denver', 'US', 'CO');
insert into public.correspondents (requester_id, addressee_id, status) values
  ('d0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000002', 'accepted');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-8000-000000000004","role":"authenticated"}';

-- Drafting runs on the write path (slowmail_reader holds insert(recipient_id,
-- body)); posting runs as the client. `id` is deliberately outside the insert
-- grant, so the draft is found again the way the app finds it.
set local role slowmail_reader;
insert into public.letters (recipient_id, body)
values ('b0000000-0000-4000-8000-000000000002', 'Sent from nowhere.');
reset role;

create temporary table nowhere_letter on commit drop as
  select id from public.letters where body = 'Sent from nowhere.';
grant select on nowhere_letter to authenticated;

set local role authenticated;
select throws_ok(
  $$ select public.post_letter((select id from nowhere_letter)) $$,
  'SM008',
  null,
  'a sender with no coordinates cannot post a letter that could never be routed'
);
reset role;

select is(
  (select state::text from public.letters where body = 'Sent from nowhere.'),
  'draft',
  'the refused letter is still a draft the sender can fix, not a wedged one'
);

-- The recipient's half of the same rule.
update public.profiles set home_lat = 39.7392, home_lng = -104.9903
 where id = 'd0000000-0000-4000-8000-000000000004';
update public.profiles set home_lat = null, home_lng = null
 where id = 'b0000000-0000-4000-8000-000000000002';

set local role authenticated;
select throws_ok(
  $$ select public.post_letter((select id from nowhere_letter)) $$,
  'SM008',
  null,
  'a recipient with no coordinates cannot be posted to either'
);
reset role;

select * from finish();
rollback;
