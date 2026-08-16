# slowmail backend

A letter is written, waits for the 5pm collection, travels for days, and lands
in the recipient's mailbox at one moment on the delivery day. **Before that
moment the recipient cannot learn the letter exists** — not the body, not the
sender, not a count, not a badge.

That rule is enforced here, in the database, and not in any client. A modified
app, a raw PostgREST call, a `count(*)`, a Realtime subscription and a foreign
key error all have to come back empty, because the product has no reason to
exist otherwise.

## Layout

```
migrations/     ordered plain SQL; no ORM
functions/      Edge Functions (Deno) — collection and push
tests/database/ pgTAP, run by `supabase test db`
tests/concurrency/  two real overlapping backends
tests/integration/  the timing engine against a real database
tests/realtime/     an empirical leak probe with a control
tests/rls_failure_drill.sh   proves the RLS suite can go red
```

## Three independent layers

The hold does not rest on one mechanism.

1. **Column privileges.** `authenticated` holds `insert (recipient_id, body)`
   and `update (body)` on `public.letters` and nothing else. A client that sends
   `deliver_at` or `state` is refused by the privilege system with `42501`
   before any policy is consulted.
2. **Row-level security.** The recipient's `SELECT` policy is gated on
   `deliver_at is not null and deliver_at <= now()`. It is time-based rather
   than state-based, so visibility does not depend on how promptly the delivery
   job ran.
3. **Triggers.** `slowmail.guard_letter_write` applies to every role, including
   the `BYPASSRLS` ones the jobs run as. After collection a letter is frozen in
   full: the guard denies by default and permits only the columns that describe
   what has happened to the letter since (`state`, `delivered_at`, `read_at`,
   `collection_claimed_at`, `updated_at`). A schedule column added later is
   frozen without anyone remembering to freeze it.

## Where the timing rules live

In `packages/mailclock`, and nowhere else. `functions/_shared/mailclock.ts` is
the single import site and re-exports the package's own types, so a change to
the contract surfaces as a type error rather than as wrong mail.

The one piece of timing logic in SQL is `slowmail.next_collection_cutoff`, which
knows about 17:00 and deliberately nothing about Sundays or federal holidays. It
exists to give a posted letter an indexable `collect_at` for the sweep. The
engine's `collectedAt` is authoritative: if it comes back in the future, the
letter stays in the postbox with the engine's corrected time. That division is
only safe if the SQL cutoff is never *late*, which is checked against every case
in `fixtures/mailclock-cases.json` rather than against expectations invented
here.

## Running the checks

Start a real local Postgres first — every suite below talks to it.

```sh
supabase start
supabase db reset          # applies all migrations from scratch
```

```sh
supabase test db                                     # pgTAP: 91 assertions
./supabase/tests/rls_failure_drill.sh                # the suite must be able to fail
./supabase/tests/concurrency/delivery_concurrency.sh # two overlapping backends

C="--config supabase/functions/deno.json"
deno run -A $C supabase/tests/integration/schedule_roundtrip.ts    # engine instants through RLS
deno run -A $C supabase/tests/integration/postgrest_count_leak.ts  # the HTTP layer, not SQL
deno run -A $C supabase/tests/integration/collection_cutoff_bound.ts
deno run -A $C supabase/tests/realtime/realtime_leak_probe.ts
deno test -A $C supabase/tests/integration/zone_bands.ts           # far zone vs territory
deno test -A $C supabase/functions/tests/                          # worker logic, no network
```

Every assertion runs under the role that would really make the request, with
real `request.jwt.claims`. This is not incidental, and it is not one rule but
three:

- Reads of `letters` run as **`slowmail_reader`**, the non-`BYPASSRLS` role the
  mailbox RPCs are owned by and the role the policies are evaluated under.
  `postgres` carries `BYPASSRLS`, so the same file run as `postgres` passes
  against a table with no security at all.
- Client RPCs run as **`authenticated`**. Running them as anything else hides a
  missing grant.
- Worker RPCs run as **`service_role`**, the role the Edge Functions
  authenticate as over PostgREST. See below for why this one is written down.

`rls_failure_drill.sh` is the answer to "how do you know the tests test
anything". It drops the `deliver_at` condition from the recipient policy,
requires the suite to go red, restores the policy, and requires it to go green.

## Two things the tests could not see, and what changed

Both were found in review, not by the suite, and both have the same shape: the
assertions were green and the property they named was broken.

**pgTAP never speaks HTTP.** PostgREST answers `Prefer: count=planned` from the
planner's row estimate, which is computed before RLS filters anything. Because
client filters go into the SQL, a *filtered* probe is a targeted oracle: a
recipient asking for their own undelivered mail got `0` with `count=exact` and a
number that tracked the hidden rows with `count=planned` — measured at 1, 3, 9
and 25 hidden letters returning 1, 2, 7 and 22. That is the existence and the
count, which is exactly what the product promises cannot be learned.
`count=estimated` is the same leak behind a row threshold, and no PostgREST
setting refuses either mode. Every SQL assertion here stayed green throughout,
because none of them make an HTTP request.

The fix removes the resource rather than the symptom: `authenticated` and `anon`
hold no privilege on `public.letters` at all, and the mailbox is served by
`mailbox()`, `outbox()` and `correspondence()`. PostgREST declines to estimate
for function calls, so there is no number to read. `postgrest_count_leak.ts` is
the standing test and it goes through HTTP for this reason.

**A grant is not part of a function's definition.** Recreating
`claim_collection_batch` in a later migration silently dropped its execute grant
to `service_role`. Collection was dead on any freshly migrated database while
90 pgTAP assertions stayed green — because those tests called it as `postgres`,
which owns it. The grant is restored, and the worker tests now run under
`set local role service_role` so the next omission fails the suite rather than
the product.

## Proving the new tests can fail

Each fix was reverted against a live stack and the matching test required to go
red:

| reverted | result |
| --- | --- |
| `revoke execute on claim_collection_batch from service_role` | 19/19 red in `050_postal_jobs` (0 red when the same suite ran as `postgres`) |
| `claim_collection_batch` rewritten to join live `profiles` | red: `have: Europe/Lisbon, want: America/New_York` |
| `drop constraint profiles_territory_excludes_states` | red: the database stored a Puerto Rico territory profile |
| push drain limited to a single batch | red: the drain stopped before the outbox was empty |

The second of those is worth reading twice. The suite was green under the
live-profile mutation until a test was added at the level where the bug can
actually happen: the original assertion checked `letters.sender_tz`, a column
written once at posting that no collection path can rewrite, so it stayed
correct while the worker ignored it completely. What can break is the value the
claim hands the engine, so that is what is asserted now.

**If a test cannot reach the stack it fails.** Pointed at a dead port,
`postgrest_count_leak.ts` exits 1. Pointed at a reachable stack with a broken
auth path, its five invariance assertions do pass vacuously — every count is the
same error string — but the control assertion that the mailbox returns the
letters that have landed fails and the run exits 1. The control is what carries
that test, not the invariances.

## Secrets

Nothing sensitive is committed. `.env.example` lists names only.

```sh
supabase secrets set --env-file supabase/.env.local   # APNs credentials
```

The cron jobs call the Edge Functions over HTTP and read their URL and
service-role key from Vault, so the key is never written into a migration:

```sql
select vault.create_secret('https://<project-ref>.functions.supabase.co', 'slowmail_functions_url');
select vault.create_secret('<service-role-key>', 'slowmail_service_role_key');
```

Until those exist the jobs log a notice and do nothing, which is the intended
behaviour on a fresh local stack.

## Two settings that must stay as they are

- **`public.letters` must never be added to a Realtime publication.** An INSERT
  event is itself proof that a letter exists. The migration asserts this, but a
  migration only runs when migrations run and enabling Realtime is one click in
  the dashboard — and PostgreSQL 17 fires no event trigger for publication DDL,
  so there is no way to hard-block it from here. Two things still hold if it
  happens: RLS filters the row out per subscriber, and `replica identity
  nothing` makes every UPDATE on the table fail outright, which stops collection
  and delivery within one cron interval. Loud, but only after the fact.
- **`db-plan-enabled` must stay off on the Data API.** PostgREST can return
  `EXPLAIN` output, and planner row estimates come from statistics that RLS does
  not filter. This is the same channel as the `count=planned` leak above.
- **`letters` must never be granted back to `authenticated`.** The count leak
  returns the moment the table is reachable over the Data API, whatever the
  policies say.

## A caveat for remote databases

These migrations assert that `letters` is not published to Realtime, but a
database that already carries `create publication supabase_realtime for all
tables` publishes `letters` the moment it is created, and the assertion does not
run until a later migration. On such a database the window is real, if brief and
local to the migration run. Check `pg_publication.puballtables` before applying
to an existing project.
