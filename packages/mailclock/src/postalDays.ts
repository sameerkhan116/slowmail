import { DateTime } from "luxon";
import { isObservedHoliday } from "./holidays.js";

/**
 * A postal day is a day the mail moves: Monday through Saturday, excluding
 * observed federal holidays. Sunday is never a postal day.
 */
export function isPostalDay(isoDate: string): boolean {
  const d = DateTime.fromISO(isoDate, { zone: "utc" });
  if (!d.isValid) throw new RangeError(`invalid date: ${isoDate}`);
  if (d.weekday === 7) return false;
  return !isObservedHoliday(isoDate);
}

/** The given date if it is a postal day, otherwise the next one. */
export function postalDayOnOrAfter(isoDate: string): string {
  let d = DateTime.fromISO(isoDate, { zone: "utc" });
  for (let i = 0; i < 30; i++) {
    const iso = d.toISODate()!;
    if (isPostalDay(iso)) return iso;
    d = d.plus({ days: 1 });
  }
  throw new Error(`no postal day within 30 days of ${isoDate}`);
}

/** The first postal day strictly after the given date. */
export function nextPostalDay(isoDate: string): string {
  return postalDayOnOrAfter(DateTime.fromISO(isoDate, { zone: "utc" }).plus({ days: 1 }).toISODate()!);
}

/** Advance `count` postal days from a date, not counting the start date itself. */
export function addPostalDays(isoDate: string, count: number): string {
  if (count < 0) throw new RangeError(`cannot advance a negative number of postal days: ${count}`);
  let cursor = isoDate;
  for (let i = 0; i < count; i++) cursor = nextPostalDay(cursor);
  return cursor;
}
