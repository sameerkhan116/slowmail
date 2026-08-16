// Collection: turn letters that are due into scheduled, in-transit mail.
//
// The database hands over a batch along with the sender's and recipient's
// routing inputs as they stand at this moment. Those inputs are written back
// onto the letter, so the schedule is a snapshot and a later move cannot
// retime mail that has already been collected.

import type { ScheduleFn } from "./mailclock.ts";

export type ClaimedLetter = {
  letter_id: string;
  written_at: string;
  sender_user_id: string;
  sender_tz: string;
  sender_lat: number | null;
  sender_lng: number | null;
  sender_country_code: string;
  sender_region: string | null;
  sender_is_territory: boolean;
  recipient_user_id: string;
  recipient_tz: string;
  recipient_lat: number | null;
  recipient_lng: number | null;
  recipient_country_code: string;
  recipient_region: string | null;
  recipient_is_territory: boolean;
};

export type CollectionDeps = {
  claimBatch: (limit: number) => Promise<ClaimedLetter[]>;
  applyResults: (results: unknown[]) => Promise<{ applied: number; rescheduled: number }>;
  schedule: ScheduleFn;
  log?: (message: string, detail?: unknown) => void;
};

export async function runCollection(
  deps: CollectionDeps,
  limit = 200,
): Promise<{ claimed: number; applied: number; rescheduled: number; skipped: number }> {
  const batch = await deps.claimBatch(limit);
  if (batch.length === 0) {
    return { claimed: 0, applied: 0, rescheduled: 0, skipped: 0 };
  }

  const results: unknown[] = [];
  let skipped = 0;

  for (const letter of batch) {
    // A profile with no coordinates cannot be routed. Leaving it unapplied
    // releases the claim on the next pass rather than guessing a destination.
    if (
      letter.sender_lat === null || letter.sender_lng === null ||
      letter.recipient_lat === null || letter.recipient_lng === null
    ) {
      skipped++;
      deps.log?.("skipping letter with an unlocatable profile", { letterId: letter.letter_id });
      continue;
    }

    try {
      const computed = deps.schedule({
        messageId: letter.letter_id,
        writtenAt: new Date(letter.written_at).toISOString(),
        sender: {
          tz: letter.sender_tz,
          lat: letter.sender_lat,
          lng: letter.sender_lng,
          countryCode: letter.sender_country_code,
          region: letter.sender_region ?? undefined,
          isTerritory: letter.sender_is_territory,
        },
        recipient: {
          userId: letter.recipient_user_id,
          tz: letter.recipient_tz,
          lat: letter.recipient_lat,
          lng: letter.recipient_lng,
          countryCode: letter.recipient_country_code,
          region: letter.recipient_region ?? undefined,
          isTerritory: letter.recipient_is_territory,
        },
      });

      results.push({
        letterId: letter.letter_id,
        // Passed through verbatim. mailclock emits ISO-8601 UTC instants and
        // YYYY-MM-DD local dates; Postgres parses both into timestamptz/date
        // without a client-side reformat, and reformatting is where time zones
        // get lost.
        collectedAt: computed.collectedAt,
        postmarkDate: computed.postmarkDate,
        transitDays: computed.transitDays,
        deliverAt: computed.deliverAt,
        scheduleSource: "mailclock",
        snapshot: {
          senderTz: letter.sender_tz,
          senderLat: letter.sender_lat,
          senderLng: letter.sender_lng,
          senderCountryCode: letter.sender_country_code,
          senderRegion: letter.sender_region,
          senderIsTerritory: letter.sender_is_territory,
          recipientTz: letter.recipient_tz,
          recipientLat: letter.recipient_lat,
          recipientLng: letter.recipient_lng,
          recipientCountryCode: letter.recipient_country_code,
          recipientRegion: letter.recipient_region,
          recipientIsTerritory: letter.recipient_is_territory,
        },
      });
    } catch (error) {
      skipped++;
      deps.log?.("scheduling failed", { letterId: letter.letter_id, error: String(error) });
    }
  }

  if (results.length === 0) {
    return { claimed: batch.length, applied: 0, rescheduled: 0, skipped };
  }

  const { applied, rescheduled } = await deps.applyResults(results);
  return { claimed: batch.length, applied, rescheduled, skipped };
}
