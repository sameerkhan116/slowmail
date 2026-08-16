#!/usr/bin/env bash
# Two delivery jobs running at the same time must deliver each letter once and
# knock on each door once.
#
# This cannot live in the pgTAP suite: those files run inside a single
# transaction that is rolled back, and a transaction cannot observe another
# transaction's locks against its own uncommitted rows. dblink is not an option
# either, because the local `postgres` role is not a superuser and the stack
# authenticates over trust, which dblink refuses for non-superusers. So this
# drives two real backends and overlaps them in wall-clock time.
#
# Emits TAP, so it can be piped into prove alongside the pgTAP suite.

set -uo pipefail

CONTAINER="${SLOWMAIL_DB_CONTAINER:-supabase_db_slowmail}"
HOLD_SECONDS="${SLOWMAIL_HOLD_SECONDS:-6}"

SENDER='a0000000-0000-4000-8000-0000000c0001'
RECIPIENT='b0000000-0000-4000-8000-0000000c0002'
LETTER_A='0c111111-0000-4000-8000-00000000000a'
LETTER_B='0c111111-0000-4000-8000-00000000000b'

psql_run() {
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1
}

tap_count=0
failures=0
ok() {
  tap_count=$((tap_count + 1))
  if [ "$2" = "$3" ]; then
    echo "ok ${tap_count} - $1"
  else
    failures=$((failures + 1))
    echo "not ok ${tap_count} - $1"
    echo "#         have: $2"
    echo "#         want: $3"
  fi
}

cleanup() {
  psql_run >/dev/null 2>&1 <<SQL
alter table public.letters disable trigger letters_guard_write;
delete from public.letters where sender_id = '${SENDER}';
alter table public.letters enable trigger letters_guard_write;
delete from slowmail.push_outbox where recipient_id = '${RECIPIENT}';
delete from auth.users where id in ('${SENDER}', '${RECIPIENT}');
SQL
}

trap cleanup EXIT

echo "1..5"

cleanup

if ! psql_run <<SQL >/dev/null
insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}');
insert into public.profiles (id, display_name, home_lat, home_lng, timezone, country_code, region) values
  ('${SENDER}', 'Ada', 40.6782, -73.9442, 'America/New_York', 'US', 'NY'),
  ('${RECIPIENT}', 'Bo', 45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR');
insert into public.correspondents (requester_id, addressee_id, status)
  values ('${SENDER}', '${RECIPIENT}', 'accepted');
insert into public.devices (user_id, apns_token) values ('${RECIPIENT}', repeat('cd', 32));
insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, delivery_date, deliver_at,
  recipient_tz, schedule_source
) values
  ('${LETTER_A}', '${SENDER}', '${RECIPIENT}', 'One.', 'in_transit',
   now() - interval '3 days', now() - interval '3 days', now() - interval '3 days',
   (now() - interval '3 days')::date, 3,
   ((now() - interval '1 minute') at time zone 'America/Los_Angeles')::date,
   now() - interval '1 minute',
   'America/Los_Angeles', 'concurrency-fixture'),
  ('${LETTER_B}', '${SENDER}', '${RECIPIENT}', 'Two.', 'in_transit',
   now() - interval '3 days', now() - interval '3 days', now() - interval '3 days',
   (now() - interval '3 days')::date, 3,
   ((now() - interval '1 minute') at time zone 'America/Los_Angeles')::date,
   now() - interval '1 minute',
   'America/Los_Angeles', 'concurrency-fixture');
SQL
then
  echo "Bail out! fixture setup failed"
  exit 1
fi

# Worker one takes the rows and sits on them without committing.
worker_one_out="$(mktemp)"
psql_run > "$worker_one_out" 2>&1 <<SQL &
begin;
select 'worker1:' || delivered || ':' || pushes_queued from slowmail.run_delivery();
select pg_sleep(${HOLD_SECONDS});
commit;
SQL
worker_one_pid=$!

# Give worker one time to take its locks, then start worker two inside the
# window where those locks are still held and uncommitted.
sleep 2

worker_two="$(psql_run <<SQL
begin;
select 'worker2:' || delivered || ':' || pushes_queued from slowmail.run_delivery();
commit;
SQL
)"

wait "$worker_one_pid"
worker_one="$(grep -o 'worker1:[0-9]*:[0-9]*' "$worker_one_out")"
rm -f "$worker_one_out"

ok "worker one delivers both letters and queues one notification" "$worker_one" "worker1:2:1"
ok "worker two, overlapping, skips the locked rows and does nothing" "$worker_two" "worker2:0:0"

delivered="$(psql_run <<SQL
select count(*) from public.letters
 where sender_id = '${SENDER}' and state = 'delivered' and delivered_at is not null;
SQL
)"
ok "both letters ended up delivered exactly once" "$delivered" "2"

outbox="$(psql_run <<SQL
select count(*) || ':' || coalesce(max(letter_count), -1) from slowmail.push_outbox
 where recipient_id = '${RECIPIENT}';
SQL
)"
ok "exactly one notification was queued, covering both letters" "$outbox" "1:2"

third="$(psql_run <<SQL
select 'third:' || delivered || ':' || pushes_queued from slowmail.run_delivery();
SQL
)"
ok "a third run after both committed delivers nothing and queues nothing" "$third" "third:0:0"

if [ "$failures" -ne 0 ]; then
  echo "# Looks like you failed ${failures} tests of ${tap_count}"
  exit 1
fi
