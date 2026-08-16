// Push worker. Woken by the delivery job whenever it queues a notification.

import { json, requireWorkerAuth, serviceClient } from "../_shared/db.ts";
import { readApnsConfig, sendMailArrivedPush } from "../_shared/apns.ts";
import { drainPushOutbox, type PushClaim } from "../_shared/push.ts";

Deno.serve(async (req) => {
  const denied = requireWorkerAuth(req);
  if (denied) return denied;

  const db = serviceClient();

  try {
    const apns = readApnsConfig();

    const summary = await drainPushOutbox({
      log: (message, detail) => console.log(JSON.stringify({ message, ...(detail as object) })),
      claimBatch: async (limit) => {
        const { data, error } = await db.rpc("claim_push_batch", { p_limit: limit });
        if (error) throw new Error(`claim_push_batch: ${error.message}`);
        return (data ?? []) as PushClaim[];
      },
      send: (token, environment) => sendMailArrivedPush(apns, token, environment),
      completePush: async (outboxId, err) => {
        const { error } = await db.rpc("complete_push", { p_outbox_id: outboxId, p_error: err });
        if (error) throw new Error(`complete_push: ${error.message}`);
      },
      pruneToken: async (token, reason) => {
        const { error } = await db.rpc("revoke_apns_token", {
          p_apns_token: token,
          p_reason: reason,
        });
        if (error) throw new Error(`revoke_apns_token: ${error.message}`);
      },
    });

    return json(summary);
  } catch (error) {
    console.error(JSON.stringify({ message: "push run failed", error: String(error) }));
    return json({ error: "push run failed" }, 500);
  }
});
