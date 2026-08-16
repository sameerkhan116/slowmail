-- The postal jobs.
--
-- Collection freezes a schedule; delivery moves letters into mailboxes and
-- queues exactly one notification per recipient per day. Both are replayed here
-- to show that a second run changes nothing.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(19);

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-000000000002'),
  ('c0000000-0000-4000-8000-000000000003');

insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada', 'Brooklyn, NY', 40.6782,  -73.9442, 'America/New_York',    'US'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',  'Portland, OR', 45.5152, -122.6784, 'America/Los_Angeles', 'US'),
  ('c0000000-0000-4000-8000-000000000003', 'Cyd', 'Chicago, IL',  41.8781,  -87.6298, 'America/Chicago',     'US');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted');

insert into public.devices (user_id, apns_token, environment) values
  ('b0000000-0000-4000-8000-000000000002', repeat('ab', 32), 'sandbox');

insert into public.letters (id, sender_id, recipient_id, body, state, written_at, collect_at) values
  ('01111111-0000-4000-8000-00000000000a',
   'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
   'First.', 'awaiting_collection', now() - interval '1 day', now() - interval '1 hour'),
  ('01111111-0000-4000-8000-00000000000b',
   'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
   'Second.', 'awaiting_collection', now() - interval '1 day', now() - interval '1 hour'),
  ('01111111-0000-4000-8000-00000000000c',
   'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
   'Not due yet.', 'awaiting_collection', now(), now() + interval '6 hours');

-- Collection -----------------------------------------------------------------

create temporary table claimed on commit drop as
  select * from public.claim_collection_batch(100);

select is(
  (select count(*)::int from claimed),
  2,
  'collection claims only the letters whose cutoff has passed'
);

select is(
  (select sender_tz from claimed where letter_id = '01111111-0000-4000-8000-00000000000a'),
  'America/New_York',
  'the claim carries the senders routing inputs as they stand right now'
);

select is(
  (select recipient_country_code from claimed where letter_id = '01111111-0000-4000-8000-00000000000a'),
  'US',
  'the claim carries the recipients routing inputs'
);

select is(
  (select count(*)::int from public.claim_collection_batch(100)),
  0,
  'a second worker starting immediately claims nothing, because the batch is already held'
);

-- The engine reports a collection instant still in the future when the cutoff
-- landed on a Sunday or a federal holiday. Those letters go back in the postbox.
select is(
  (select rescheduled from public.apply_collection(jsonb_build_array(
     jsonb_build_object(
       'letterId', '01111111-0000-4000-8000-00000000000b',
       'collectedAt', (now() + interval '2 days')::text,
       'postmarkDate', (now() + interval '2 days')::date::text,
       'transitDays', 2,
       'deliverAt', (now() + interval '4 days')::text,
       'scheduleSource', 'test-fixture',
       'snapshot', '{}'::jsonb
     )
   ))),
  1,
  'a collection instant in the future pushes the letter back to awaiting_collection'
);

select is(
  (select state::text from public.letters where id = '01111111-0000-4000-8000-00000000000b'),
  'awaiting_collection',
  'the rescheduled letter is still waiting'
);

select ok(
  (select collect_at > now() and collection_claimed_at is null
     from public.letters where id = '01111111-0000-4000-8000-00000000000b'),
  'the rescheduled letter has a corrected cutoff and a released claim'
);

select is(
  (select applied from public.apply_collection(jsonb_build_array(
     jsonb_build_object(
       'letterId', '01111111-0000-4000-8000-00000000000a',
       'collectedAt', (now() - interval '30 minutes')::text,
       'postmarkDate', (now() - interval '30 minutes')::date::text,
       'transitDays', 3,
       'deliverAt', (now() + interval '3 days')::text,
       'scheduleSource', 'test-fixture',
       'snapshot', jsonb_build_object(
         'senderTz', 'America/New_York', 'senderLat', 40.6782, 'senderLng', -73.9442,
         'senderCountryCode', 'US', 'senderIsTerritory', false,
         'recipientTz', 'America/Los_Angeles', 'recipientLat', 45.5152, 'recipientLng', -122.6784,
         'recipientCountryCode', 'US'
       )
     )
   ))),
  1,
  'a collection instant in the past moves the letter into transit'
);

select is(
  (select state::text from public.letters where id = '01111111-0000-4000-8000-00000000000a'),
  'in_transit',
  'the collected letter is in transit'
);

-- Replaying the same payload, as a retried worker would.
select is(
  (select applied from public.apply_collection(jsonb_build_array(
     jsonb_build_object(
       'letterId', '01111111-0000-4000-8000-00000000000a',
       'collectedAt', (now() - interval '30 minutes')::text,
       'postmarkDate', (now() - interval '30 minutes')::date::text,
       'transitDays', 3,
       'deliverAt', (now() + interval '3 days')::text,
       'scheduleSource', 'test-fixture',
       'snapshot', '{}'::jsonb
     )
   ))),
  0,
  'replaying a collection payload applies nothing the second time'
);

-- The snapshot is the point: a sender who moves does not teleport mail that has
-- already been collected.
update public.profiles
   set timezone = 'Europe/Lisbon', country_code = 'PT', home_lat = 38.72, home_lng = -9.14
 where id = 'a0000000-0000-4000-8000-000000000001';

select is(
  (select sender_tz from public.letters where id = '01111111-0000-4000-8000-00000000000a'),
  'America/New_York',
  'a sender moving abroad does not rewrite the routing of a letter already in transit'
);

-- Delivery -------------------------------------------------------------------

select is(
  (select delivered from slowmail.run_delivery()),
  0,
  'delivery leaves a letter alone until its instant arrives'
);

-- Two letters to the same recipient, both due, both landing on the same
-- recipient-local day.
insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, deliver_at,
  recipient_tz, schedule_source
) values (
  '02222222-0000-4000-8000-00000000000a',
  'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
  'Due now.', 'in_transit',
  now() - interval '3 days', now() - interval '3 days', now() - interval '3 days',
  (now() - interval '3 days')::date, 3, now() - interval '2 minutes',
  'America/Los_Angeles', 'test-fixture'
), (
  '02222222-0000-4000-8000-00000000000b',
  'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
  'Also due now.', 'in_transit',
  now() - interval '3 days', now() - interval '3 days', now() - interval '3 days',
  (now() - interval '3 days')::date, 3, now() - interval '2 minutes',
  'America/Los_Angeles', 'test-fixture'
);

create temporary table run1 on commit drop as select * from slowmail.run_delivery();

select is(
  (select delivered from run1), 2,
  'both due letters are delivered'
);

select is(
  (select pushes_queued from run1), 1,
  'two letters landing on the same day for the same person queue one notification, because the carrier comes once'
);

select is(
  (select letter_count from slowmail.push_outbox
    where recipient_id = 'b0000000-0000-4000-8000-000000000002'),
  2,
  'the single notification records how many letters arrived'
);

-- A second run, as a job that fired twice would.
select results_eq(
  $$ select delivered, pushes_queued from slowmail.run_delivery() $$,
  $$ values (0, 0) $$,
  'running the delivery job again delivers nothing and queues no second notification'
);

select is(
  (select count(*)::int from slowmail.push_outbox),
  1,
  'the outbox still holds exactly one notification'
);

-- Push claiming ---------------------------------------------------------------

select results_eq(
  $$ select apns_token, environment from public.claim_push_batch(10) $$,
  $$ values (repeat('ab', 32), 'sandbox') $$,
  'the push worker is handed the recipients live device tokens and nothing about the letters'
);

select is(
  (select count(*)::int from public.claim_push_batch(10)),
  0,
  'a claimed notification is not handed to a second push worker'
);

select * from finish();
rollback;
