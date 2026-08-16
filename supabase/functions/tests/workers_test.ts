// Worker logic, exercised without a network or a database.
//
// The schedule function here is a fixture, not a second implementation of the
// postal rules: it returns fixed instants so the assertions are about what the
// worker does with a schedule, never about what the schedule should be. The
// real rules live in packages/mailclock and are tested there.

import { assertEquals } from "jsr:@std/assert@1";
import { runCollection, type ClaimedLetter } from "../_shared/collection.ts";
import { drainPushOutbox, type PushClaim } from "../_shared/push.ts";
import type { ScheduleFn } from "../_shared/mailclock.ts";

const COLLECTED = "2026-08-17T21:00:00.000Z";
const DELIVER = "2026-08-20T18:30:00.000Z";

const fixedSchedule: ScheduleFn = () => ({
  collectedAt: COLLECTED,
  postmarkDate: "2026-08-17",
  transitDays: 3,
  deliveryDate: "2026-08-20",
  deliverAt: DELIVER,
  isInternational: false,
});

function claimedLetter(overrides: Partial<ClaimedLetter> = {}): ClaimedLetter {
  return {
    letter_id: "11111111-0000-4000-8000-00000000000a",
    written_at: "2026-08-17T14:02:00.000Z",
    sender_user_id: "a0000000-0000-4000-8000-000000000001",
    sender_tz: "America/New_York",
    sender_lat: 40.6782,
    sender_lng: -73.9442,
    sender_country_code: "US",
    sender_region: "NY",
    sender_is_territory: false,
    recipient_user_id: "b0000000-0000-4000-8000-000000000002",
    recipient_tz: "America/Los_Angeles",
    recipient_lat: 45.5152,
    recipient_lng: -122.6784,
    recipient_country_code: "US",
    recipient_region: "OR",
    recipient_is_territory: false,
    ...overrides,
  };
}

Deno.test("collection passes the letter id to the engine, so jitter stays deterministic", async () => {
  let seenMessageId: string | null = null;

  await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter()]),
    applyResults: () => Promise.resolve({ applied: 1, rescheduled: 0 }),
    schedule: (input) => {
      seenMessageId = input.messageId;
      return fixedSchedule(input);
    },
  });

  assertEquals(seenMessageId, "11111111-0000-4000-8000-00000000000a");
});

Deno.test("collection writes back the routing inputs it was handed, not fresh ones", async () => {
  let applied: Record<string, unknown> | null = null;

  await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter()]),
    applyResults: (results) => {
      applied = results[0] as Record<string, unknown>;
      return Promise.resolve({ applied: 1, rescheduled: 0 });
    },
    schedule: fixedSchedule,
  });

  assertEquals(applied!.deliverAt, DELIVER);
  assertEquals(applied!.collectedAt, COLLECTED);
  assertEquals(applied!.postmarkDate, "2026-08-17");
  assertEquals(applied!.snapshot, {
    senderTz: "America/New_York",
    senderLat: 40.6782,
    senderLng: -73.9442,
    senderCountryCode: "US",
    senderRegion: "NY",
    senderIsTerritory: false,
    recipientTz: "America/Los_Angeles",
    recipientLat: 45.5152,
    recipientLng: -122.6784,
    recipientCountryCode: "US",
    recipientRegion: "OR",
    recipientIsTerritory: false,
  });
});

Deno.test("collection leaves an unlocatable letter alone rather than guessing", async () => {
  let applyCalled = false;

  const summary = await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter({ recipient_lat: null, recipient_lng: null })]),
    applyResults: () => {
      applyCalled = true;
      return Promise.resolve({ applied: 0, rescheduled: 0 });
    },
    schedule: fixedSchedule,
  });

  assertEquals(applyCalled, false);
  assertEquals(summary, { claimed: 1, applied: 0, rescheduled: 0, skipped: 1 });
});

Deno.test("one letter failing to schedule does not sink the rest of the batch", async () => {
  const applied: unknown[] = [];

  const summary = await runCollection({
    claimBatch: () =>
      Promise.resolve([
        claimedLetter({ letter_id: "11111111-0000-4000-8000-00000000000a" }),
        claimedLetter({ letter_id: "11111111-0000-4000-8000-00000000000b" }),
      ]),
    applyResults: (results) => {
      applied.push(...results);
      return Promise.resolve({ applied: results.length, rescheduled: 0 });
    },
    schedule: (input) => {
      if (input.messageId.endsWith("a")) throw new Error("unroutable");
      return fixedSchedule(input);
    },
  });

  assertEquals(applied.length, 1);
  assertEquals(summary.skipped, 1);
  assertEquals(summary.applied, 1);
});

function pushClaim(overrides: Partial<PushClaim> = {}): PushClaim {
  return {
    outbox_id: "0b111111-0000-4000-8000-00000000000a",
    recipient_id: "b0000000-0000-4000-8000-000000000002",
    delivery_date: "2026-08-20",
    apns_token: "a".repeat(64),
    environment: "production",
    ...overrides,
  };
}

Deno.test("one recipient with three devices is still one notification", async () => {
  const sentTo: string[] = [];
  const completed: string[] = [];

  const summary = await drainPushOutbox({
    claimBatch: () =>
      Promise.resolve([
        pushClaim({ apns_token: "a".repeat(64) }),
        pushClaim({ apns_token: "b".repeat(64) }),
        pushClaim({ apns_token: "c".repeat(64) }),
      ]),
    send: (token) => {
      sentTo.push(token);
      return Promise.resolve({ ok: true } as const);
    },
    completePush: (id) => {
      completed.push(id);
      return Promise.resolve();
    },
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(sentTo.length, 3);
  assertEquals(completed, ["0b111111-0000-4000-8000-00000000000a"]);
  assertEquals(summary, { notifications: 1, sent: 1, pruned: 0, failed: 0 });
});

Deno.test("a dead token is pruned and does not hold the notification open", async () => {
  const pruned: string[] = [];
  let completedWith: string | null | undefined;

  const summary = await drainPushOutbox({
    claimBatch: () => Promise.resolve([pushClaim({ apns_token: "d".repeat(64) })]),
    send: () =>
      Promise.resolve(
        { ok: false, retryable: false, reason: "Unregistered", pruneToken: true } as const,
      ),
    completePush: (_id, err) => {
      completedWith = err;
      return Promise.resolve();
    },
    pruneToken: (token) => {
      pruned.push(token);
      return Promise.resolve();
    },
  });

  assertEquals(pruned, ["d".repeat(64)]);
  assertEquals(completedWith, null);
  assertEquals(summary, { notifications: 1, sent: 0, pruned: 1, failed: 0 });
});

Deno.test("a temporary APNs failure leaves the notification to be retried", async () => {
  let completedWith: string | null | undefined;

  const summary = await drainPushOutbox({
    claimBatch: () => Promise.resolve([pushClaim()]),
    send: () => Promise.resolve({ ok: false, retryable: true, reason: "TooManyRequests" } as const),
    completePush: (_id, err) => {
      completedWith = err;
      return Promise.resolve();
    },
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(completedWith, "TooManyRequests");
  assertEquals(summary.failed, 1);
  assertEquals(summary.sent, 0);
});

Deno.test("a recipient with no live device has their notification closed out", async () => {
  let completedWith: string | null | undefined;

  const summary = await drainPushOutbox({
    claimBatch: () => Promise.resolve([pushClaim({ apns_token: null, environment: null })]),
    send: () => {
      throw new Error("must not attempt to send without a token");
    },
    completePush: (_id, err) => {
      completedWith = err;
      return Promise.resolve();
    },
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(completedWith, null);
  assertEquals(summary, { notifications: 1, sent: 0, pruned: 0, failed: 0 });
});
