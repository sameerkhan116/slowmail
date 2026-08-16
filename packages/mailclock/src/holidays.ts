import { DateTime } from "luxon";

/**
 * US federal holidays, as observed by USPS.
 *
 * Computed from the rules rather than tabulated per year, so this keeps working
 * without maintenance. Note that the *observed* date is what matters: a holiday
 * on a Saturday closes the Friday before, and one on a Sunday closes the Monday
 * after, because mail moves on the observed day, not the nominal one.
 */

type FixedHoliday = { readonly month: number; readonly day: number };
type FloatingHoliday = {
  readonly month: number;
  /** 1 = Monday .. 7 = Sunday, matching Luxon's `weekday`. */
  readonly weekday: number;
  /** Positive for nth from the start of the month, -1 for the last. */
  readonly nth: number;
};

const FIXED: readonly FixedHoliday[] = [
  { month: 1, day: 1 },   // New Year's Day
  { month: 6, day: 19 },  // Juneteenth
  { month: 7, day: 4 },   // Independence Day
  { month: 11, day: 11 }, // Veterans Day
  { month: 12, day: 25 }, // Christmas Day
];

const FLOATING: readonly FloatingHoliday[] = [
  { month: 1, weekday: 1, nth: 3 },   // MLK Day
  { month: 2, weekday: 1, nth: 3 },   // Presidents Day
  { month: 5, weekday: 1, nth: -1 },  // Memorial Day
  { month: 9, weekday: 1, nth: 1 },   // Labor Day
  { month: 10, weekday: 1, nth: 2 },  // Columbus Day
  { month: 11, weekday: 4, nth: 4 },  // Thanksgiving
];

function nthWeekdayOfMonth(year: number, month: number, weekday: number, nth: number): string {
  if (nth > 0) {
    const first = DateTime.fromObject({ year, month, day: 1 }, { zone: "utc" });
    const delta = (weekday - first.weekday + 7) % 7;
    return first.plus({ days: delta + (nth - 1) * 7 }).toISODate()!;
  }
  const last = DateTime.fromObject({ year, month, day: 1 }, { zone: "utc" }).endOf("month").startOf("day");
  const delta = (last.weekday - weekday + 7) % 7;
  return last.minus({ days: delta }).toISODate()!;
}

/** Shift a nominal date to the day USPS actually closes. */
function observed(isoDate: string): string {
  const d = DateTime.fromISO(isoDate, { zone: "utc" });
  if (d.weekday === 6) return d.minus({ days: 1 }).toISODate()!; // Saturday -> Friday
  if (d.weekday === 7) return d.plus({ days: 1 }).toISODate()!;  // Sunday -> Monday
  return isoDate;
}

const cache = new Map<number, ReadonlySet<string>>();

/** Observed federal holiday dates (YYYY-MM-DD) for a calendar year. */
export function observedHolidays(year: number): ReadonlySet<string> {
  const cached = cache.get(year);
  if (cached) return cached;

  const dates = new Set<string>();
  for (const h of FIXED) {
    const nominal = DateTime.fromObject({ year, month: h.month, day: h.day }, { zone: "utc" }).toISODate()!;
    // Both dates close the mail. When Independence Day lands on a Saturday the
    // Post Office shuts the Friday before, and nothing moves on the Fourth
    // either, so a Saturday holiday costs two days rather than shifting one.
    dates.add(nominal);
    dates.add(observed(nominal));
  }
  for (const h of FLOATING) {
    // Floating holidays always land on a weekday, so no observation shift applies.
    dates.add(nthWeekdayOfMonth(year, h.month, h.weekday, h.nth));
  }

  // A New Year's Day falling on a Saturday is observed on Dec 31 of the prior
  // year, so that closure belongs to this year's set from the mail's point of view.
  const nextNewYear = DateTime.fromObject({ year: year + 1, month: 1, day: 1 }, { zone: "utc" });

  const inYear = new Set([...dates].filter((d) => d.startsWith(`${year}-`)));
  if (nextNewYear.weekday === 6) inYear.add(nextNewYear.minus({ days: 1 }).toISODate()!);

  const frozen: ReadonlySet<string> = inYear;
  cache.set(year, frozen);
  return frozen;
}

export function isObservedHoliday(isoDate: string): boolean {
  const year = Number(isoDate.slice(0, 4));
  return observedHolidays(year).has(isoDate);
}
