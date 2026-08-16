#!/usr/bin/env bash
# Proof that the hold-until-delivery suite can fail.
#
# A security test that cannot go red is worse than no test, because it reads
# like evidence. This weakens the recipient policy to the one thing that matters
# -- it drops the `deliver_at <= now()` condition and leaves only the ownership
# check -- runs the suite, and requires it to fail. Then it puts the policy back
# and requires it to pass again.
#
# Run it whenever the letters policies change.

set -uo pipefail

CONTAINER="${SLOWMAIL_DB_CONTAINER:-supabase_db_slowmail}"
SUITE="$(cd "$(dirname "$0")" && pwd)/database/010_letters_rls_hold_until_delivery.sql"

psql_run() {
  docker exec -i "$CONTAINER" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1
}

restore_policy() {
  psql_run >/dev/null <<'SQL'
alter policy letters_select_recipient on public.letters
  using (
    recipient_id = (select slowmail.current_user_id())
    and deliver_at is not null
    and deliver_at <= now()
  );
SQL
}

trap restore_policy EXIT

echo "== weakening letters_select_recipient: dropping the deliver_at condition =="
psql_run >/dev/null <<'SQL'
alter policy letters_select_recipient on public.letters
  using (recipient_id = (select slowmail.current_user_id()));
SQL

weakened_output="$(psql_run < "$SUITE" 2>&1)"
echo "$weakened_output"

if ! grep -q '^not ok' <<<"$weakened_output"; then
  echo
  echo "FAIL: the suite passed against a policy with no delivery gate."
  echo "The early-read assertions are not testing what they claim to test."
  exit 1
fi

echo
echo "== restoring letters_select_recipient =="
restore_policy
trap - EXIT

restored_output="$(psql_run < "$SUITE" 2>&1)"

if grep -q '^not ok' <<<"$restored_output"; then
  echo "$restored_output"
  echo
  echo "FAIL: the suite is still red after restoring the policy."
  exit 1
fi

echo "$restored_output" | tail -n 5
echo
echo "PASS: the suite goes red without the delivery gate and green with it."
