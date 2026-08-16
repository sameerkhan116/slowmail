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
supabase test db                                     # pgTAP: 111 assertions
./supabase/tests/rls_failure_drill.sh                # the suite must be able to fail
./supabase/tests/concurrency/delivery_concurrency.sh # two overlapping backends

C="--config supabase/functions/deno.json"
deno run -A $C supabase/tests/integration/schedule_roundtrip.ts    # engine instants through RLS
deno run -A $C supabase/tests/integration/postgrest_count_leak.ts  # the HTTP layer, not SQL
deno run -A $C supabase/tests/integration/reader_role_hardening.ts # the role the hold rests on
deno run -A $C supabase/tests/integration/collection_cutoff_bound.ts
deno run -A $C supabase/tests/integration/timezone_agreement.ts    # every accepted zone
deno run -A $C supabase/tests/integration/timezone_legacy_repair.ts
deno run -A $C supabase/tests/realtime/realtime_leak_probe.ts
deno test -A $C supabase/tests/integration/zone_bands.ts           # far zone vs territory
deno test -A $C supabase/functions/tests/                          # worker logic, no network
```

Give the realtime probe about half a minute after a `db reset`. It subscribes to
a control table it knows produces events, and the realtime service takes a
moment to pick up publication changes after a reset — so a run started
immediately reports `INCONCLUSIVE` and exits 1 rather than reading its own
silence as proof. That refusal is the point: without the control, "letters
delivered 0 events" is exactly what a disconnected probe reports too.

`zone_bands.ts` is the one suite built on `Deno.test`, so it needs `deno test`.
Started with `deno run` it would register its cases, run none, print nothing and
exit 0 — passing by not existing. It now refuses that invocation and exits 1.

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

## The role the hold rests on

Taking `letters` off the Data API moved the whole hold onto one role. The mailbox
functions are `SECURITY DEFINER` and owned by `slowmail_reader` precisely because
that role has neither `BYPASSRLS` nor ownership of the table, so
`letters_select_recipient` still applies inside the function body. Every property
in this README is downstream of that one attribute being off.

`create role ... if not exists` is therefore not enough. On a database where a
role of that name already exists, the migration would adopt it — and a
pre-existing `slowmail_reader` carrying `BYPASSRLS` turns the hold off with no
error anywhere. The migration now normalises the role unconditionally after
creating it, warns about every dangerous attribute it found already set, and
re-checks afterwards.

`SUPERUSER` is the exception and it aborts instead, because it cannot be
repaired: `ALTER ROLE ... NOSUPERUSER` requires the *caller* to be a superuser,
and the migration role is not one — it fails even when the target is an ordinary
role. Nothing else aborts, because aborting would roll back the same migration's
`revoke ... on public.letters`, and failing closed on the role would mean failing
open on the table the role exists to protect.

`reader_role_hardening.ts` measures the leak rather than asserting the catalog
bit. It sets `BYPASSRLS` on the role and watches the recipient's own count of
in-transit mail go from 0 to 1, then re-applies the migration and watches it go
back to 0. It also asserts that `postgres` reads 1 in *both* states — the same
assertion written as `postgres` cannot tell a working hold from a disabled one,
which is the third time that shape has come up here.

## What a correspondent can read about you

`correspondent_card` returns three columns — id, display name, home city label —
and nothing else, so a request never discloses the routing coordinates,
`region` or `is_territory` that a profile carries. It is filtered to `pending`
and `accepted` edges: an edge is a record that something happened, not a standing
permission, so `declined` and `blocked` return nothing. Blocking someone has to
stop them reading you or it is not blocking.

Accepting someone is a different matter. An accepted correspondent can read the
full profile, coordinates included. That is deliberate rather than overlooked —
it is the deal you make by accepting, and it is what lets a client show where
mail is coming from — but it is the one place where a social action hands over a
location.

## When the two runtimes disagree about a timezone

Postgres resolves a timezone string against abbreviations *before* full zone
names, so `at time zone 'CET'` is a fixed +01:00 all year. Luxon, which the
engine uses, reads `CET` as a DST-observing zone. In European summer the SQL
cutoff lands at 16:00Z and the engine's at 15:00Z, and in that hour the letter
is still `awaiting_collection` — which is to say still revocable, an hour after
five o'clock has passed. `EET`, `MET` and `WET` collide identically.

`collection_cutoff_bound.ts` could not see it: 13 fixture cases in two zones
sample the property rather than establish it. `timezone_agreement.ts` sweeps
**every zone the profile constraint will accept** (554 today, 8800 probes) on
each zone's own DST transition days and the days either side, and fails if SQL
is ever later than the engine. It derives its zone list by attempting an insert
of each zone into `profiles` inside a rolled-back transaction, so it cannot
drift out of step with the constraint it is testing.

The fix rejects the whole abbreviation namespace rather than the four names
known to disagree today: every IANA region zone contains a `/`, so requiring one
(plus `UTC`) rules out the class and does not rot as Postgres adds
abbreviations. Existing rows are repaired first — all 45 slashless names have a
canonical `Region/City` equivalent — so the CHECK on `profiles` goes on
validated rather than `NOT VALID`. The four broken names map to zones matching
*Luxon's* reading (`CET` → `Europe/Paris`), which is the side that was already
authoritative, so the repair corrects SQL rather than moving anyone's mail.
`letters.sender_tz` is repaired and `collect_at` recomputed for uncollected
letters only; a collected letter's envelope is frozen and stays that way.

## One arrival per recipient per day

`carrierArrival` seeds the carrier's minute offset on `(userId, localDate)` — so
that, as its docstring says, every letter due that day arrives together — but it
turns that offset into an instant using the timezone it is handed. Same user,
same `2026-11-01`: `America/New_York` 18:52Z, `America/Los_Angeles` 21:52Z,
`Europe/London` 13:52Z. Each letter freezes the recipient's zone at posting, so
two letters posted either side of a move genuinely disagree, share a delivery
date, and land hours apart. The post comes, and then more post comes; and
`run_delivery` folds both into one outbox row, so the second may arrive with no
push at all.

`slowmail.arrival_bundles` makes the instant a fact about the day rather than
about the letter: one row per `(recipient_id, delivery_date)`, written once by
whichever letter is collected first, and every letter for that date takes its
`deliver_at` from it.

Two decisions worth stating, because both could reasonably go the other way:

- **The recipient's live profile zone computes the bundle**, not the letter's
  snapshot. *How long the post takes* was settled at posting and stays frozen on
  the envelope — coordinates, regions, territory flags and country codes are all
  still read from the snapshot. *What time the carrier calls* is a fact about
  where the recipient is standing. Scheduling from the first-collected letter's
  snapshot would serve someone who has moved to Los Angeles at New York times,
  06:52 local, which is not a time any carrier calls. The bound on what a
  recipient can move by changing zone is 26 hours (UTC-12 to UTC+14), it always
  stays within 09:00–17:00 on the delivery date *in the zone chosen*, and it
  cannot reach earlier than that date in the recipient's own frame — so it is
  not a hold violation. It is also blind: a recipient cannot see undelivered
  mail, so cannot know whether there is a bundle to move.
- **A bundle already written is never recomputed.** Moving after it exists takes
  effect on days not yet scheduled. Recomputing would either drag mail forward
  (a hold violation) or push back a letter that may already have landed.

One exception, and it is deliberate: a bundle instant can fall *before* a given
letter's own `collected_at`, in which case the letter keeps its own
engine-computed `deliverAt` and is marked `+unbundled`.

Arriving before it was posted is not a competing good that loses — it is
unrepresentable. `letters_collected_is_routed` requires `deliver_at >=
collected_at`, so a letter that took such an instant could not be stored at all.
And the fallback cannot itself fail: the inversion is not a property of extreme
zone spread — probed across the full 25-hour range over every ordered pair of
Midway, Kiritimati, Apia, Pago Pago, Tokyo and New York at minimum transit
distance, the engine produces **no inversion at all, with 90 hours of margin at
the tightest** — it is a property of *sharing* an instant. A bundle is fixed by
whichever letter is collected first, and a later letter can be collected after
it. Falling back to the engine's own answer restores an instant derived from
this letter's own collection, which is exactly what the engine guarantees.

The consequence, named rather than fixed: an `+unbundled` letter is a second
arrival on a day that already had one — the very thing bundling exists to
prevent. It is not a hold issue, since every letter is still invisible until its
own `deliver_at`, and it requires the recipient to have moved most of the way
around the world between two postings due on the same date. Correctness about
what can be stored outranks tidiness about what arrives together, so it stays.

No change to `packages/mailclock` was needed. Its `carrierArrival` docstring
overpromises, though: it can only make good on "every letter due that day
arrives together" for a fixed timezone, and the obligation to pass a consistent
one per bundle belongs to the caller.

## The outbox shows posted mail

`letter_state` includes `draft`, `outbox()` had no state filter, and the client
renders anything not in transit or delivered as awaiting collection — so a draft
would have been shown as "will be collected at 5pm" about mail that has no
`collect_at` and that no sweep will ever pick up.

No client can produce that today. `write_letter` creates and posts in one
statement, `authenticated` holds no privilege on `public.letters` at all, and
`slowmail_reader` is NOLOGIN NOINHERIT with only `postgres` as a member. But
"unreachable today" is the kind of guarantee that quietly stops being true, and
the cost of it stopping is a shipped client lying about mail. `outbox()` now
excludes drafts, which changes how a future save-draft path fails: drafts are
absent from the outbox, which whoever builds that path sees on their first run,
rather than rendering as posted mail in a client nobody thought to change. A
wrong answer in production becomes a missing answer in development.

This removes the only read path to a draft, which is why the pgTAP suite had to
stop looking one up through `outbox()`. No client needs it: `write_letter`
returns the row.

## Routing inputs that cannot route

Two shapes of profile produced a letter that no worker could ever deliver.

`is_territory` is client-writable and nothing derived it from `region`, so an
account holder could hold `region = 'AE'` with `is_territory = false` and pull a
7-day route down to a one-day band. `profiles_territories_are_flagged` requires
the flag for `AA/AE/AP/GU/VI/AS/MP`. Puerto Rico is deliberately *excluded* from
that list and from the flag: the spec puts PR in the 5-day band with AK and HI,
and `zones.ts` checks `isTerritory` before region, so a flagged PR profile
routes at 7. PR is `region = 'PR', is_territory = false`, and the constraint
either side of that is what keeps it so.

`post_letter` snapshots the routing inputs, and a profile with no coordinates
snapshots nulls. Collection then cannot route the letter, and completing the
profile later cannot repair it, because repairing a frozen envelope is exactly
the recomputation the snapshot exists to prevent. `post_letter` now refuses the
post with `SM008` — the last moment at which the profile is still the source of
truth and the sender is still there to be told. The letter stays a draft they
can fix.

The worker's own guard was half-built: it skipped an unroutable letter without
releasing the claim, so the row was retried every 15 minutes forever and nothing
reported it. It now releases the claim and records the reason.

## Asserting the whole contract, not two fields of it

The worker test that checks what the collection job hands the engine used to
compare the two timezones and the two regions. Swapping the sender and recipient
coordinate pairs inside `claim_collection_batch`, or hardcoding both territory
flags to `false`, left it green — and both of those are wrong routes, not wrong
formatting. It now captures the entire `ScheduleInput` and compares it field by
field against distinct per-field sentinels, so a field added to the engine's
contract fails the test until somebody asserts it.

That is the same fail-open shape as the freeze trigger's original allowlist, and
it is fixed the same way: enumerate what must be true rather than what must not.

## Proving the new tests can fail

Each fix was reverted against a live stack and the matching test required to go
red:

| reverted | result |
| --- | --- |
| `revoke execute on claim_collection_batch from service_role` | 19/19 red in `050_postal_jobs` (0 red when the same suite ran as `postgres`) |
| `claim_collection_batch` rewritten to join live `profiles` | red: `have: Europe/Lisbon, want: America/New_York` |
| `drop constraint profiles_territory_excludes_states` | red: the database stored a Puerto Rico territory profile |
| push drain limited to a single batch | red: the drain stopped before the outbox was empty |
| the whole `slowmail_reader` normalisation block removed | 3/8 red in `reader_role_hardening`, including the behavioural one: *the recipient is back to seeing 1 letters* |
| `correspondent_card` status filter removed | 2 red in `040_leak_vectors`: `declined` and `blocked` edges both returned the card |
| the `state <> 'draft'` filter removed from `outbox()` | 1 red in `020_letters_write_surface` — and only that one: the draft is still in the table and the outbox still non-empty, so the control assertions correctly stayed green |
| the `/`-requiring timezone predicate removed | red in `timezone_agreement`: *the SQL cutoff runs LATE in 4 zones (56 probes)* — `CET`, `EET`, `MET`, `WET`, 60 minutes each, out of 598 swept |
| `apply_collection` reverted to each letter's own `deliver_at` | 3 red in `050_postal_jobs`, including *two letters due the same day arrive at one instant, not two* |
| `drop constraint profiles_territories_are_flagged` | 8 red in `zone_bands`: all seven territory regions stored unflagged, and the flag cleared by a later `UPDATE` |
| `post_letter`'s coordinate checks removed | 3 red in `020_letters_write_surface` — including the behavioural one, *the refused letter is still a draft*, which went red because the letter reached `awaiting_collection` with null coordinates |
| `recipient_live_tz` swapped back to the frozen `recipient_tz` | 1 red in `workers_test` |
| sender and recipient coordinates swapped in the engine call | 1 red in `workers_test` — the previous two-field assertion stayed green through this |
| both territory flags hardcoded `false` in the engine call | 1 red in `workers_test` — likewise |

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
