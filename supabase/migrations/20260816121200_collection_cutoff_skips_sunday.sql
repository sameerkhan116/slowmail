-- Teach the sweep cutoff about Sundays.
--
-- This function is not a port of the postal rules and must not become one. It
-- exists to give a posted letter a cheap, indexable `collect_at`; the engine's
-- `collectedAt` is authoritative and replaces it at collection. The only
-- property it owes is that it is never *later* than the real collection, so the
-- sweep never leaves a letter sitting past its pickup. Being early is harmless:
-- apply_collection asks the engine, gets an instant in the future, and puts the
-- letter back with the corrected time.
--
-- Sunday is worth the one predicate anyway, because it is the one day where
-- being early is visible to a user rather than merely internal. The iOS app
-- estimates arrival with the same weekday rule (SlowmailCore.PostalCalendar
-- skips Sundays and deliberately models no holidays), so without this a letter
-- posted on a Sunday reads "collected Monday" in the app and "collected Sunday"
-- on the server until the first sweep reconciles them -- about fifty-two days a
-- year of the two disagreeing.
--
-- Federal holidays stay out of both sides on purpose. A second copy of the
-- holiday table here could drift from the engine's, and eleven days a year where
-- both the app and the sweep are early and both defer to the engine is a better
-- trade than two tables that can disagree.
create or replace function slowmail.next_collection_cutoff(p_timezone text, p_from timestamptz default now())
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
           -- Sunday itself never has a pickup, whatever the hour.
           when local_now::time < time '17:00' and extract(dow from local_now) <> 0
             then date_trunc('day', local_now) + interval '17 hours'
           -- Otherwise the next day, unless that lands on a Sunday. Only Sundays
           -- are skipped here, so one roll is always enough.
           when extract(dow from date_trunc('day', local_now) + interval '1 day') = 0
             then date_trunc('day', local_now) + interval '2 days' + interval '17 hours'
           else date_trunc('day', local_now) + interval '1 day' + interval '17 hours'
         end at time zone p_timezone
  from (select p_from at time zone p_timezone as local_now) s;
$$;

revoke all on function slowmail.next_collection_cutoff(text, timestamptz) from public;
