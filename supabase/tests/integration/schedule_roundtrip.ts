// End-to-end: does a real mailclock instant survive the trip into Postgres and
// mean the right thing to the RLS predicate?
//
// The concern this answers is narrow and serious. mailclock emits deliverAt as
// an ISO-8601 UTC string with milliseconds. RLS compares `deliver_at <= now()`
// on a timestamptz column. If the string were parsed in the server's local
// zone, or truncated, or compared as text, the hold would break silently in one
// direction or the other and every existing pgTAP test would still pass,
// because those tests write their own timestamps rather than mailclock's.
//
// So nothing here invents a timestamp. Two letters go through the real
// claim -> schedule -> apply path with the real engine, one written a month ago
// and one written three days ago. No clock is moved and no deliver_at is edited: the
// engine decides which one has landed, and RLS is asked what the recipient can
// see.
//
//   deno run -A supabase/tests/integration/schedule_roundtrip.ts

import { runCollection, type ClaimedLetter } from "../../functions/_shared/collection.ts";
import { schedule } from "../../functions/_shared/mailclock.ts";

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";

const SENDER = "41111111-0000-4000-8000-000000000001";
const RECIPIENT = "41111111-0000-4000-8000-000000000002";
const STRANGER = "41111111-0000-4000-8000-000000000003";
const LANDED = "4a000000-0000-4000-8000-000000000001";
const IN_FLIGHT = "4a000000-0000-4000-8000-000000000002";

async function psql(sql: string): Promise<string> {
  const p = new Deno.Command("docker", {
    args: ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const w = p.stdin.getWriter();
  await w.write(new TextEncoder().encode(sql));
  await w.close();
  const out = await p.output();
  if (!out.success) throw new Error(`psql failed:\n${new TextDecoder().decode(out.stderr)}`);
  return new TextDecoder().decode(out.stdout).trim();
}

const results: Array<[boolean, string]> = [];
const ok = (pass: boolean, name: string) => results.push([pass, name]);

// A read performed as the real authenticated role with the real JWT claims.
// Running these as postgres would prove nothing: that role carries BYPASSRLS.
const asUser = (userId: string, query: string) => `
  begin;
  set local request.jwt.claims = '{"sub":"${userId}","role":"authenticated"}';
  set local role authenticated;
  ${query}
  rollback;
`;

await psql(`
  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where id in ('${LANDED}', '${IN_FLIGHT}');
  alter table public.letters enable trigger letters_guard_write;
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}', '${STRANGER}');

  insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}'), ('${STRANGER}');
  insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code, region) values
    ('${SENDER}',    'Roundtrip Sender',    'Brooklyn, NY',  40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
    ('${RECIPIENT}', 'Roundtrip Recipient', 'Portland, OR',  45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR'),
    ('${STRANGER}',  'Roundtrip Stranger',  'Chicago, IL',   41.8781,  -87.6298, 'America/Chicago',     'US', 'IL');
  insert into public.correspondents (requester_id, addressee_id, status, responded_at)
    values ('${SENDER}', '${RECIPIENT}', 'accepted', now());

  -- Both are ordinary posted letters awaiting collection. Only written_at
  -- differs, and the engine draws every other instant from that.
  insert into public.letters (id, sender_id, recipient_id, body, state, written_at, collect_at) values
    ('${LANDED}',    '${SENDER}', '${RECIPIENT}', 'Posted a month ago.', 'awaiting_collection',
      now() - interval '30 days', now() - interval '30 days'),
    ('${IN_FLIGHT}', '${SENDER}', '${RECIPIENT}', 'Posted this week.',   'awaiting_collection',
      now() - interval '3 days', now() - interval '3 days');
`);

const claimed: ClaimedLetter[] = JSON.parse(
  await psql(`select coalesce(json_agg(t), '[]'::json) from public.claim_collection_batch(200) t;`),
);
ok(claimed.length === 2, `collection claimed ${claimed.length} letter(s)`);
ok(
  claimed.every((c) => c.sender_region === "NY" && c.recipient_region === "OR"),
  "the claim hands the engine region, not just lat/lng, so far-zone states can be priced",
);

// The real engine, called exactly as the Edge Function calls it.
let sentToDb: Record<string, unknown>[] = [];
const summary = await runCollection({
  claimBatch: () => Promise.resolve(claimed),
  applyResults: async (r) => {
    sentToDb = r as Record<string, unknown>[];
    const applied = await psql(
      `select row_to_json(t) from public.apply_collection($json$${JSON.stringify(r)}$json$::jsonb) t;`,
    );
    return JSON.parse(applied);
  },
  schedule,
});
ok(summary.applied === 2, `apply_collection moved ${summary.applied} letter(s) into transit`);

const byId = new Map(sentToDb.map((r) => [r.letterId as string, r]));
const landedIso = byId.get(LANDED)?.deliverAt as string;
const inFlightIso = byId.get(IN_FLIGHT)?.deliverAt as string;

ok(
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(landedIso ?? ""),
  `engine emits a millisecond UTC instant: ${landedIso}`,
);
ok(new Date(landedIso).getTime() < Date.now(), `the month-old letter has landed (${landedIso})`);
ok(new Date(inFlightIso).getTime() > Date.now(), `the letter posted now is still in transit (${inFlightIso})`);

// Equality against the engine's own string, not against a re-rendering of it.
// `=` on timestamptz compares absolute instants, so this fails if the string
// was ever read in the wrong zone.
const exact = await psql(`
  select
    (deliver_at = '${landedIso}'::timestamptz),
    to_char(deliver_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  from public.letters where id = '${LANDED}';
`);
const [sameInstant, rendered] = exact.split("|");
ok(sameInstant === "t", "stored timestamptz is the same instant the engine returned");
ok(rendered === landedIso, `stored value round-trips back to the identical string: ${rendered}`);

// The whole point: RLS, asked as the recipient, over instants nobody hand-wrote.
const visible = await psql(asUser(RECIPIENT, `select id from public.letters order by id;`));
const visibleIds = visible.split("\n").filter(Boolean);
ok(
  visibleIds.length === 1 && visibleIds[0] === LANDED,
  `recipient sees exactly the landed letter (${visibleIds.join(", ") || "none"})`,
);

const counted = await psql(asUser(RECIPIENT, `select count(*) from public.letters;`));
ok(counted === "1", `recipient's count(*) is ${counted}, so the aggregate agrees with the rows`);

const named = await psql(asUser(RECIPIENT, `select count(*) from public.letters where id = '${IN_FLIGHT}';`));
ok(named === "0", `naming the in-transit letter's id returns ${named} rows`);

const senderSees = await psql(asUser(SENDER, `select count(*) from public.letters;`));
ok(senderSees === "2", `sender still sees both letters at every stage (${senderSees})`);

const strangerSees = await psql(asUser(STRANGER, `select count(*) from public.letters;`));
ok(strangerSees === "0", `an unrelated third user sees ${strangerSees} letters`);

await psql(`
  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where id in ('${LANDED}', '${IN_FLIGHT}');
  alter table public.letters enable trigger letters_guard_write;
  delete from slowmail.push_outbox where recipient_id = '${RECIPIENT}';
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}', '${STRANGER}');
`);

console.log(`1..${results.length}`);
results.forEach(([pass, name], i) => console.log(`${pass ? "ok" : "not ok"} ${i + 1} - ${name}`));
if (results.some(([pass]) => !pass)) Deno.exit(1);
console.log("\nPASS: mailclock's instants reach the RLS predicate intact.");
