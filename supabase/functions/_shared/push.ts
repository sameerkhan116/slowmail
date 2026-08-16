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
  pruneToken: (token: string, reason: string) => Promise<void>;
  log?: (message: string, detail?: unknown) => void;
};

export async function drainPushOutbox(
  deps: PushDeps,
  limit = 200,
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

    if (anyDelivered || failures.length === 0) {
      await deps.completePush(outboxId, null);
      if (anyDelivered) sent++;
    } else {
      await deps.completePush(outboxId, failures.join(", "));
      failed++;
    }
  }

  return { notifications: byNotification.size, sent, pruned, failed };
}
