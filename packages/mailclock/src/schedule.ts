import { DateTime } from "luxon";
import { nextCollection } from "./collection.js";
import { carrierArrival, rollToDeliveryDay, transitJitter } from "./delivery.js";
import { haversineMiles } from "./distance.js";
import { internationalTransitDays } from "./international.js";
import { addPostalDays } from "./postalDays.js";
import type { Schedule, ScheduleInput } from "./types.js";
import { baseDomesticTransitDays } from "./zones.js";

/** No letter, however close, arrives the day it was collected. */
const MINIMUM_TRANSIT_DAYS = 1;

/**
 * The whole life of a letter, decided the moment it is written.
 *
 * Deterministic: same input, same output, forever. Callers persist the result
 * at collection time and never recompute it, so that a correspondent moving
 * house cannot retime mail already in the system.
 */
export function schedule(input: ScheduleInput): Schedule {
  const { messageId, writtenAt, sender, recipient } = input;

  const collection = nextCollection(writtenAt, sender.tz);
  const isInternational = sender.countryCode.toUpperCase() !== recipient.countryCode.toUpperCase();

  let transitDays: number;
  let deliveryDate: string;

  if (isInternational) {
    transitDays = internationalTransitDays(messageId, recipient.countryCode);
    const nominal = DateTime.fromISO(collection.postmarkDate, { zone: "utc" })
      .plus({ days: transitDays })
      .toISODate()!;
    deliveryDate = rollToDeliveryDay(nominal, recipient.countryCode);
  } else {
    const miles = haversineMiles(sender.lat, sender.lng, recipient.lat, recipient.lng);
    const base = baseDomesticTransitDays(miles, sender, recipient);
    transitDays = Math.max(MINIMUM_TRANSIT_DAYS, base + transitJitter(messageId));
    deliveryDate = addPostalDays(collection.postmarkDate, transitDays);
  }

  let deliverAt = carrierArrival(recipient.userId, deliveryDate, recipient.tz);

  // Postmark dates are sender-local and delivery dates recipient-local, so a
  // large westward time-zone gap can otherwise land the carrier before the box
  // was even emptied. Mail cannot arrive before it is collected.
  let guard = 0;
  while (deliverAt <= collection.at) {
    if (++guard > 30) throw new Error(`could not place delivery after collection for ${messageId}`);
    deliveryDate = rollToDeliveryDay(
      DateTime.fromISO(deliveryDate, { zone: "utc" }).plus({ days: 1 }).toISODate()!,
      recipient.countryCode,
    );
    deliverAt = carrierArrival(recipient.userId, deliveryDate, recipient.tz);
  }

  return {
    collectedAt: collection.at,
    postmarkDate: collection.postmarkDate,
    transitDays,
    deliveryDate,
    deliverAt,
    isInternational,
  };
}
