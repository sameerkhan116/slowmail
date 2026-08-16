import { seededIntInRange, seededUnit } from "./hash.js";
import { wallClock } from "./collection.js";
import { isPostalDay } from "./postalDays.js";
import { DateTime } from "luxon";

/** Mail arrives somewhere in the working part of the day, never on a schedule. */
export const ARRIVAL_WINDOW_START_HOUR = 9;
export const ARRIVAL_WINDOW_END_HOUR = 17;
const WINDOW_MINUTES = (ARRIVAL_WINDOW_END_HOUR - ARRIVAL_WINDOW_START_HOUR) * 60;

/**
 * The moment a given recipient's carrier reaches them on a given day.
 *
 * Seeded on the person and the date, so every letter due that day arrives
 * together, and so the app can show the same answer twice.
 */
export function carrierArrival(userId: string, localDate: string, tz: string): string {
  const offset = seededIntInRange(0, WINDOW_MINUTES - 1, "carrier-arrival", userId, localDate);
  const hour = ARRIVAL_WINDOW_START_HOUR + Math.floor(offset / 60);
  return wallClock(localDate, hour, offset % 60, tz).toUTC().toISO()!;
}

/**
 * Transit jitter, in days.
 *
 * Service standards are a distribution, not a promise. Roughly a fifth of mail
 * runs a day late and a tenth arrives early; the rest lands on the nose.
 */
export function transitJitter(messageId: string): -1 | 0 | 1 {
  const u = seededUnit("transit-jitter", messageId);
  if (u < 0.2) return 1;
  if (u < 0.3) return -1;
  return 0;
}

/**
 * Move a date forward to one where mail is actually delivered in that country.
 *
 * Only US holiday calendars are modelled. Elsewhere we know Sunday is off and
 * assume every other day works, which will occasionally deliver on a national
 * holiday abroad. Per-country calendars plug in here.
 */
export function rollToDeliveryDay(isoDate: string, countryCode: string): string {
  let cursor = isoDate;
  for (let i = 0; i < 30; i++) {
    if (countryCode.toUpperCase() === "US") {
      if (isPostalDay(cursor)) return cursor;
    } else if (DateTime.fromISO(cursor, { zone: "utc" }).weekday !== 7) {
      return cursor;
    }
    cursor = DateTime.fromISO(cursor, { zone: "utc" }).plus({ days: 1 }).toISODate()!;
  }
  throw new Error(`no delivery day within 30 days of ${isoDate}`);
}
