import { DateTime } from "luxon";
import { isPostalDay, nextPostalDay } from "./postalDays.js";

/** The blue box is emptied once a day, at 17:00 local. */
export const COLLECTION_HOUR = 17;

/**
 * Build a wall-clock time in a zone.
 *
 * Luxon resolves times skipped by a DST jump forward into the gap. That is the
 * behaviour we want — a carrier does not skip the day because the clock moved —
 * but it means the returned local hour may not equal the requested one on those
 * two days a year. Callers that care should read the returned DateTime.
 */
export function wallClock(isoDate: string, hour: number, minute: number, zone: string): DateTime {
  const [year, month, day] = isoDate.split("-").map(Number) as [number, number, number];
  const dt = DateTime.fromObject({ year, month, day, hour, minute }, { zone });
  if (!dt.isValid) throw new RangeError(`invalid local time ${isoDate} ${hour}:${minute} in ${zone}: ${dt.invalidReason}`);
  return dt;
}

export interface Collection {
  /** UTC instant of collection. */
  readonly at: string;
  /** Sender-local date stamped on the letter. */
  readonly postmarkDate: string;
}

/**
 * When a letter written at `writtenAt` gets picked up.
 *
 * Before 17:00 on a postal day it makes today's collection. At or after 17:00,
 * or on any day the mail does not move, it waits for the next postal day.
 */
export function nextCollection(writtenAt: string, senderTz: string): Collection {
  const local = DateTime.fromISO(writtenAt, { zone: senderTz });
  if (!local.isValid) throw new RangeError(`invalid instant ${writtenAt}: ${local.invalidReason}`);

  const today = local.toISODate()!;
  const madeTodaysPickup = isPostalDay(today) && local.hour < COLLECTION_HOUR;
  const postmarkDate = madeTodaysPickup ? today : nextPostalDay(today);

  return {
    at: wallClock(postmarkDate, COLLECTION_HOUR, 0, senderTz).toUTC().toISO()!,
    postmarkDate,
  };
}
