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
supabase test db                                     # pgTAP: 90 assertions
./supabase/tests/rls_failure_drill.sh                # the suite must be able to fail
./supabase/tests/concurrency/delivery_concurrency.sh # two overlapping backends
deno run -A --config supabase/functions/deno.json \
  supabase/tests/integration/schedule_roundtrip.ts   # engine instants through RLS
deno run -A supabase/tests/integration/collection_cutoff_bound.ts
deno run -A supabase/tests/realtime/realtime_leak_probe.ts
cd supabase/functions && deno test tests/            # worker logic, no network
```

The pgTAP tests run as the `authenticated` role with real
`request.jwt.claims`. This is not incidental. The `postgres` role carries
`BYPASSRLS`, so the same file run as `postgres` passes against a table with no
security at all.

`rls_failure_drill.sh` is the answer to "how do you know the tests test
anything". It drops the `deliver_at` condition from the recipient policy,
requires the suite to go red, restores the policy, and requires it to go green.

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
  not filter.
