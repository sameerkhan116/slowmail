// The one place the timing engine is imported.
//
// Every postal rule -- 17:00 collection, postal days, distance bands, jitter,
// the per-recipient arrival time -- belongs to packages/mailclock. Nothing in
// supabase/ reimplements any of it, and nothing here restates its types: they
// are re-exported from the package so a change to the contract shows up as a
// type error in the workers rather than as wrong mail six hours later.
//
// The package is plain TypeScript with NodeNext-style ./x.js specifiers, which
// is why deno.json enables sloppy-imports and maps luxon to npm:.

export { nextCollection, schedule } from "@slowmail/mailclock";
export type { Party, Recipient, Schedule, ScheduleInput } from "@slowmail/mailclock";

import type { schedule as scheduleImpl } from "@slowmail/mailclock";

export type ScheduleFn = typeof scheduleImpl;
