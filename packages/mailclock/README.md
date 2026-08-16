# @slowmail/mailclock

The postal rules: when a letter is collected, how long it travels, and the moment
it lands. Pure functions, no clock reads, no I/O — every answer is a function of
its arguments, so the app, the server, and any future port agree.

## The rules

**Collection.** The box is emptied at 17:00 sender-local on every postal day
(Monday–Saturday, excluding observed US federal holidays). Before 17:00 you make
today's pickup; at or after it, you wait for the next postal day. The collection
instant is the point of no return.

**Domestic transit**, in postal days from the postmark:

| Distance | Days |
| --- | --- |
| ≤ 50 mi | 1 |
| 51–300 mi | 2 |
| 301–1,000 mi | 3 |
| 1,001–1,800 mi | 4 |
| 1,801+ mi, or either party in AK/HI/PR | 5 |
| US territories and APO/FPO | 7 |

Then jitter: about a fifth of letters run a day late, a tenth a day early, never
below one day. Seeded on the letter id, so it is fixed the moment the letter
exists and identical everywhere.

**International transit** is calendar days drawn from a per-region band (7–10 for
Canada and Mexico, up to 14–25 for Africa and remote islands), rolled forward off
Sunday. Unrecognised countries get the broad 12–21 band.

**Delivery.** Each recipient has one arrival moment per day, seeded on the person
and the date, uniform in 09:00–17:00 local. Everything due that day arrives
together, because the carrier comes once.

## Using it

```ts
import { schedule } from "@slowmail/mailclock";

const s = schedule({
  messageId: "letter-0010",
  writtenAt: "2026-08-20T16:59:59-04:00",
  sender: { tz: "America/New_York", lat: 40.7128, lng: -74.006, countryCode: "US", region: "NY" },
  recipient: { userId: "u-philly", tz: "America/New_York", lat: 39.9526, lng: -75.1652, countryCode: "US", region: "PA" },
});
// { collectedAt: "2026-08-20T21:00:00.000Z", postmarkDate: "2026-08-20",
//   transitDays: 2, deliveryDate: "2026-08-22",
//   deliverAt: "2026-08-22T13:03:00.000Z", isInternational: false }
```

Persist the result at collection time and never recompute it. Recomputing would
let a correspondent who moves house retime mail already in the system.

## The fixture contract

`fixtures/mailclock-cases.json` at the repo root is the authority, not this
implementation. It pins holiday observation, postal-day arithmetic, distance
bands, jitter branches, and 18 end-to-end schedules including both daylight-saving
boundaries and a date-line crossing. Any port must reproduce it exactly.

## Verifying

```sh
npm install
npm test        # 90 tests, fixtures plus properties
npm run typecheck
```
