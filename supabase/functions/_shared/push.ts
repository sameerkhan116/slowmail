// Draining the notification outbox.
//
// One notification per recipient per delivery day was already decided in SQL;
// this only fans it out across that person's live devices. A recipient with no
// device still gets their outbox row closed, otherwise it would be retried
// until it was abandoned.

import type { ApnsOutcome } from "./apns.ts";

export type PushClaim = {
  outbox_id: string;
  recipient_id: string;
  delivery_date: string;
  apns_token: string | null;
  environment: string | null;
};

export type PushDeps = {
  claimBatch: (limit: number) => Promise<PushClaim[]>;
  send: (token: string, environment: string | null) => Promise<ApnsOutcome>;
  completePush: (outboxId: string, error: string | null) => Promise<void>;
  recordDelivery: (outboxId: string, token: string) => Promise<void>;
  pruneToken: (token: string, reason: string) => Promise<void>;
  log?: (message: string, detail?: unknown) => void;
};

export type PushSummary = {
  notifications: number;
  sent: number;
  pruned: number;
  failed: number;
  batches: number;
};

// Keep claiming until the outbox stops offering work. A single pass left
// anything past the claim limit waiting for the next *new* delivery to wake the
// worker, which on a quiet evening is never. The cap is a guard against a row
// that keeps releasing itself, not an expected stopping point.
export async function drainPushOutbox(
  deps: PushDeps,
  limit = 200,
  maxBatches = 50,
): Promise<PushSummary> {
  const total: PushSummary = { notifications: 0, sent: 0, pruned: 0, failed: 0, batches: 0 };

  for (let i = 0; i < maxBatches; i++) {
    const batch = await drainOnce(deps, limit);
    total.notifications += batch.notifications;
    total.sent += batch.sent;
    total.pruned += batch.pruned;
    total.failed += batch.failed;
    total.batches++;
    if (batch.notifications < limit) break;
  }

  return total;
}

async function drainOnce(
  deps: PushDeps,
  limit: number,
): Promise<{ notifications: number; sent: number; pruned: number; failed: number }> {
  const claims = await deps.claimBatch(limit);

  const byNotification = new Map<string, PushClaim[]>();
  for (const claim of claims) {
    const group = byNotification.get(claim.outbox_id) ?? [];
    group.push(claim);
    byNotification.set(claim.outbox_id, group);
  }

  let sent = 0;
  let pruned = 0;
  let failed = 0;

  for (const [outboxId, group] of byNotification) {
    const tokens = group.filter((row): row is PushClaim & { apns_token: string } =>
      row.apns_token !== null
    );

    if (tokens.length === 0) {
      await deps.completePush(outboxId, null);
      continue;
    }

    let anyDelivered = false;
    const failures: string[] = [];

    for (const row of tokens) {
      const outcome = await deps.send(row.apns_token, row.environment);

      if (outcome.ok) {
        anyDelivered = true;
        // Recorded before the row is closed so that if this notification is
        // retried for a different device, the one that already answered is not
        // knocked on twice.
        await deps.recordDelivery(outboxId, row.apns_token);
        continue;
      }

      if (!outcome.retryable) {
        await deps.pruneToken(row.apns_token, outcome.reason);
        pruned++;
        // A dead token is not a failed notification. If every token for this
        // person is dead there is nowhere left to knock, so the row is closed
        // rather than retried forever.
        continue;
      }

      failures.push(outcome.reason);
      deps.log?.("apns send failed", { outboxId, reason: outcome.reason });
    }

    // A success on one device used to close the row, which stranded every
    // other device behind a retryable error. What matters is whether anything
    // is still owed, not whether anything got through.
    if (failures.length === 0) {
      await deps.completePush(outboxId, null);
      if (anyDelivered) sent++;
    } else {
      await deps.completePush(outboxId, failures.join(", "));
      failed++;
    }
  }

  return { notifications: byNotification.size, sent, pruned, failed };
}
