# slowmail

Messages delivered like physical mail.

You write to someone whenever you like. The letter sits in your outbox until the
day's collection at 5pm, and you can fetch it back until then. After that it is
out of your hands: it travels for a number of days that depends on how far away
the other person is, and lands in their mailbox once, at a time of day the
carrier decides. There is no send button that means *now*.

## The rules

Taken from how USPS actually works.

**Collection** at 17:00 sender-local on postal days — Monday to Saturday, minus
the eleven federal holidays. Written before 17:00 goes today; at or after, or on
a Sunday or holiday, goes on the next postal day.

**Transit** counted in postal days by distance: 1 day under 50 miles, 2 under
300, 3 under 1000, 4 under 1800, 5 beyond that and for Alaska, Hawaii and Puerto
Rico, 7 for other territories and APO. International counts calendar days and
only skips Sunday, because other countries don't observe US holidays.

**Delivery** once per recipient per day, at a time drawn between 09:00 and 17:00
recipient-local. Everything that lands that day lands together, because one
carrier walks one round. Give or take a day, seeded on the letter, because real
mail isn't a timer.

A letter does not exist for its recipient until it is delivered. Not in their
mailbox, not in the thread, not as a row count.

## Layout

| | |
|---|---|
| `fixtures/mailclock-cases.json` | The contract: 74 cases every implementation is checked against. |
| `packages/mailclock` | The scheduling engine, TypeScript. |
| `ios/Packages/MailClockKit` | The same engine in Swift. |
| `ios/` | The app. Delegates to MailClockKit and carries no postal arithmetic of its own. |
| `supabase/` | Where the hold is actually enforced: Postgres row-level security, not client filtering. |

Two implementations of the same arithmetic will drift, and these did: the app's
carrier-arrival calculation and the engine's disagreed three ways, and for one
recipient on one day the app said 11:40 while the engine said 12:23. Nothing
failed. The app would have told someone the post had come and brought nothing,
forty minutes before their letter arrived. The fixture file exists so that
divergence is a test failure, and the app delegates so there is nothing left to
diverge.

## Running the tests

```
cd packages/mailclock && npm install && npx vitest run   # 91
cd ios && ./Scripts/test.sh                              # 103 app, 11 engine
supabase start && supabase test db                       # 111 pgTAP assertions
```

The backend has its own suites beyond pgTAP — integration, concurrency and a
Realtime leak probe. `supabase/README.md` lists them and explains why each one
exists.

A letter is withheld by the database, so that is where the withholding is
tested. `./supabase/tests/rls_failure_drill.sh` deletes the single policy
condition that implements the hold and requires the suite to go red; a suite
that stays green when the hold is removed is not testing the hold.

Every test here has been shown to fail against a deliberately broken version of
the code it covers. That isn't thoroughness for its own sake — ten separate
measurements in this project reported success while checking nothing:

- a Swift test target that reported `✔ Test run with 0 tests in 0 suites passed`
  and exited 0, because `unsafeFlags` linked a runtime SwiftPM couldn't
  introspect
- the same failure again in the database suite, where one file was invoked with
  `deno run` instead of `deno test`: it registered its cases, ran none, printed
  nothing and exited 0
- a database suite running as `postgres`, so a missing grant that would have
  stopped all collection sat behind 90 green assertions
- an assertion on a column that no code path rewrote, which stayed correct while
  the code it was meant to cover was reverted
- invariance checks that passed because every value they compared was the same
  error string
- optional decoding keys asserted only against `null` fixtures, where a
  misspelled key and an absent field are indistinguishable — every such
  assertion compared two absences and could not fail
- a daylight-saving test that could not fail, because Foundation rolls a skipped
  midnight forward rather than back, so the broken and correct calculations
  returned the same answer
- a mutation harness that twice scored its own results wrong, in both directions

The last one is the reason for the rest. A test that cannot fail is worse than
no test: it occupies the space where a real check would go. So the harness now
requires each mutation to actually match the source before it is scored, the
Swift runner refuses a run that discovered no tests, and the one file that must
never be run the wrong way exits 1 if it is.

## Timezones

Client and server agree on the wall-clock time the carrier comes and can
disagree on when that was. Swift ships one copy of the timezone database and
Node's ICU ships another; where they disagree about a zone's rules, the same
local time is up to an hour apart as an instant. The client treats its own
answer as an estimate and keeps watching for an hour past it. The server is the
only authority on what has landed, and nothing shown to a recipient claims the
day is over.

## Building the app

Xcode isn't needed for the tests or the screenshots —
`ios/Scripts/screenshots.sh` draws every screen to PNG through `ImageRenderer`
against the macOS SDK. It is needed to run on a device. Dynamic Type layout is
unverified, because macOS ignores `dynamicTypeSize` under `ImageRenderer` and
checking it needs a simulator.
