// Worker logic, exercised without a network or a database.
//
// The schedule function here is a fixture, not a second implementation of the
// postal rules: it returns fixed instants so the assertions are about what the
// worker does with a schedule, never about what the schedule should be. The
// real rules live in packages/mailclock and are tested there.

import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
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
    releaseClaim: () => Promise.resolve(),
    applyResults: () => Promise.resolve({ applied: 1, rescheduled: 0 }),
    schedule: (input) => {
      seenMessageId = input.messageId;
      return fixedSchedule(input);
    },
  });

  assertEquals(seenMessageId, "11111111-0000-4000-8000-00000000000a");
});

Deno.test("collection routes from the frozen envelope and never restates it", async () => {
  // The routing inputs are frozen onto the letter when it is posted, so the
  // worker's job is to route from what it was handed and write back only the
  // schedule. If it echoed the address back it would be a second writer for
  // columns that are supposed to have stopped moving at posting time.
  let applied: Record<string, unknown> | null = null;
  let seen: Record<string, unknown> | null = null;

  await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter()]),
    releaseClaim: () => Promise.resolve(),
    applyResults: (results) => {
      applied = results[0] as Record<string, unknown>;
      return Promise.resolve({ applied: 1, rescheduled: 0 });
    },
    schedule: ((input: Parameters<ScheduleFn>[0]) => {
      seen = input as unknown as Record<string, unknown>;
      return fixedSchedule(input);
    }) as ScheduleFn,
  });

  assertEquals(applied!.deliverAt, DELIVER);
  assertEquals(applied!.collectedAt, COLLECTED);
  assertEquals(applied!.postmarkDate, "2026-08-17");
  // Nothing address-shaped goes back to the database.
  assertEquals(applied!.snapshot, undefined);

  // The engine is fed the letter's own frozen values.
  const sender = (seen!.sender as Record<string, unknown>);
  const recipient = (seen!.recipient as Record<string, unknown>);
  assertEquals(sender.tz, "America/New_York");
  assertEquals(sender.region, "NY");
  assertEquals(recipient.tz, "America/Los_Angeles");
  assertEquals(recipient.region, "OR");
});

Deno.test("collection leaves an unlocatable letter alone rather than guessing", async () => {
  let applyCalled = false;

  const summary = await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter({ recipient_lat: null, recipient_lng: null })]),
    releaseClaim: () => Promise.resolve(),
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
    releaseClaim: () => Promise.resolve(),
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
    recordDelivery: () => Promise.resolve(),
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(sentTo.length, 3);
  assertEquals(completed, ["0b111111-0000-4000-8000-00000000000a"]);
  assertEquals(summary, { notifications: 1, sent: 1, pruned: 0, failed: 0, batches: 1 });
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
    recordDelivery: () => Promise.resolve(),
    pruneToken: (token) => {
      pruned.push(token);
      return Promise.resolve();
    },
  });

  assertEquals(pruned, ["d".repeat(64)]);
  assertEquals(completedWith, null);
  assertEquals(summary, { notifications: 1, sent: 0, pruned: 1, failed: 0, batches: 1 });
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
    recordDelivery: () => Promise.resolve(),
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
    recordDelivery: () => Promise.resolve(),
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(completedWith, null);
  assertEquals(summary, { notifications: 1, sent: 0, pruned: 0, failed: 0, batches: 1 });
});

Deno.test("a letter the engine refuses to schedule gives its claim back", async () => {
  // Without this the row keeps collection_claimed_at forever, is skipped by
  // every later sweep, and nothing anywhere says why.
  const released: Array<{ id: string; reason: string }> = [];

  const summary = await runCollection({
    claimBatch: () => Promise.resolve([claimedLetter({ sender_tz: "posix/America/New_York" })]),
    releaseClaim: (id, reason) => {
      released.push({ id, reason });
      return Promise.resolve();
    },
    applyResults: () => Promise.resolve({ applied: 0, rescheduled: 0 }),
    schedule: () => {
      throw new Error("Invalid time zone specified: posix/America/New_York");
    },
  });

  assertEquals(summary.skipped, 1);
  assertEquals(released.length, 1);
  assertStringIncludes(released[0].reason, "posix/America/New_York");
});

Deno.test("one device failing temporarily keeps the notification open for it", async () => {
  // The old rule closed the row as soon as anything got through, so the device
  // that returned 503 never heard about the letter at all.
  let completedError: string | null = null;
  const recorded: string[] = [];

  const summary = await drainPushOutbox({
    claimBatch: (limit) =>
      Promise.resolve(
        limit === 0 ? [] : [
          pushClaim({ apns_token: "a".repeat(64) }),
          pushClaim({ apns_token: "b".repeat(64) }),
        ],
      ),
    send: (token) =>
      Promise.resolve(
        token.startsWith("a")
          ? { ok: true } as const
          : { ok: false, retryable: true, reason: "ServiceUnavailable" } as const,
      ),
    completePush: (_id, err) => {
      completedError = err;
      return Promise.resolve();
    },
    recordDelivery: (_id, token) => {
      recorded.push(token);
      return Promise.resolve();
    },
    pruneToken: () => Promise.resolve(),
  });

  assertEquals(summary.sent, 0);
  assertEquals(summary.failed, 1);
  assertStringIncludes(String(completedError), "ServiceUnavailable");
  // The device that answered is recorded, so the retry will not knock twice.
  assertEquals(recorded, ["a".repeat(64)]);
});

Deno.test("the drain keeps claiming until the outbox stops offering work", async () => {
  // A single pass left everything past the claim limit waiting for the next new
  // delivery, which on a quiet evening never comes.
  const pages = [
    [pushClaim({ outbox_id: "1" }), pushClaim({ outbox_id: "2" })],
    [pushClaim({ outbox_id: "3" })],
  ];
  let call = 0;

  const summary = await drainPushOutbox({
    claimBatch: () => Promise.resolve(pages[call++] ?? []),
    send: () => Promise.resolve({ ok: true } as const),
    completePush: () => Promise.resolve(),
    recordDelivery: () => Promise.resolve(),
    pruneToken: () => Promise.resolve(),
  }, 2);

  assertEquals(summary.notifications, 3);
  assertEquals(summary.batches, 2);
});
