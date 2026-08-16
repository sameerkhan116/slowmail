// Collection worker. Woken every five minutes by pg_cron.

import { json, requireWorkerAuth, serviceClient } from "../_shared/db.ts";
import { runCollection, type ClaimedLetter } from "../_shared/collection.ts";
import { schedule } from "../_shared/mailclock.ts";

Deno.serve(async (req) => {
  const denied = requireWorkerAuth(req);
  if (denied) return denied;

  const db = serviceClient();

  try {
    const summary = await runCollection({
      schedule,
      log: (message, detail) => console.log(JSON.stringify({ message, ...(detail as object) })),
      claimBatch: async (limit) => {
        const { data, error } = await db.rpc("claim_collection_batch", { p_limit: limit });
        if (error) throw new Error(`claim_collection_batch: ${error.message}`);
        return (data ?? []) as ClaimedLetter[];
      },
      releaseClaim: async (letterId, reason) => {
        const { error } = await db.rpc("release_collection_claim", {
          p_letter_id: letterId,
          p_reason: reason,
        });
        if (error) throw new Error(`release_collection_claim: ${error.message}`);
      },
      applyResults: async (results) => {
        const { data, error } = await db.rpc("apply_collection", { p_results: results });
        if (error) throw new Error(`apply_collection: ${error.message}`);
        const row = Array.isArray(data) ? data[0] : data;
        return { applied: row?.applied ?? 0, rescheduled: row?.rescheduled ?? 0 };
      },
    });

    return json(summary);
  } catch (error) {
    console.error(JSON.stringify({ message: "collection run failed", error: String(error) }));
    return json({ error: "collection run failed" }, 500);
  }
});
