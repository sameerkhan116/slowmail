// Reproduction harness for a PostgREST-layer count leak.
//
// Claim under test: `Prefer: count=planned` returns the planner's row estimate,
// and the planner does not know what RLS will filter out, so a recipient can
// issue two requests, subtract, and learn how many letters are in the air
// addressed to them.
//
// This is deliberately built to distinguish two very different outcomes that
// would both look like "planned != exact":
//
//   A. planned tracks the recipient's own row count including undelivered mail
//      -> a targeted leak, exactly as reported, and fatal.
//   B. planned tracks the whole table, including other people's letters
//      -> still an information leak, but it does not tell the recipient
//         anything about mail addressed to *them*, and the subtract-two-numbers
//         attack yields a wrong answer.
//
// So the fixture gives an unrelated third party a distinctive number of letters
// (7). If the planned count comes back near 20 the leak is targeted; if it comes
// back near 27 it is whole-table; if it is 19 there is no leak; if it is 1000 the
// planner is just returning a default.
//
//   deno run -A supabase/tests/integration/postgrest_count_leak.ts

import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const REST = (Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321") + "/rest/v1";
// The Supabase CLI's published default for `supabase start`. A local test
// constant, not a credential.
const JWT_SECRET = Deno.env.get("SUPABASE_JWT_SECRET") ??
  "super-secret-jwt-token-with-at-least-32-characters-long";
const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";

const SENDER = "51111111-0000-4000-8000-000000000001";
const RECIPIENT = "51111111-0000-4000-8000-000000000002";
const THIRD = "51111111-0000-4000-8000-000000000003";

const DELIVERED = 19;
const IN_FLIGHT = Number(Deno.env.get("SLOWMAIL_IN_FLIGHT") ?? "1");
const THIRD_PARTY_LETTERS = 7;

const key = await crypto.subtle.importKey(
  "raw",
  new TextEncoder().encode(JWT_SECRET),
  { name: "HMAC", hash: "SHA-256" },
  false,
  ["sign", "verify"],
);

const mint = (sub: string | null, role: string) =>
  create({ alg: "HS256", typ: "JWT" }, {
    ...(sub ? { sub } : {}),
    role,
    aud: "authenticated",
    iss: "supabase",
    exp: getNumericDate(60 * 60),
  }, key);

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

const anonKey = await mint(null, "anon");

/** Returns the total from a Content-Range header, e.g. "0-0/20" -> 20. */
async function countVia(
  jwt: string,
  countMode: "exact" | "planned" | "estimated",
  resource: string,
): Promise<{ total: string; status: number }> {
  const res = await fetch(`${REST}/${resource}`, {
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${jwt}`,
      Prefer: `count=${countMode}`,
      Range: "0-0",
      "Range-Unit": "items",
    },
  });
  await res.body?.cancel();
  const range = res.headers.get("content-range") ?? "";
  return { total: range.split("/")[1] ?? `no content-range (status ${res.status})`, status: res.status };
}

const results: Array<[boolean, string]> = [];
const ok = (pass: boolean, name: string) => results.push([pass, name]);

// Fixtures -------------------------------------------------------------------

await psql(`
  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where sender_id = '${SENDER}' or recipient_id = '${SENDER}';
  alter table public.letters enable trigger letters_guard_write;
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}', '${THIRD}');

  insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}'), ('${THIRD}');
  insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code, region) values
    ('${SENDER}',    'Count Sender',    'Brooklyn, NY', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
    ('${RECIPIENT}', 'Count Recipient', 'Portland, OR', 45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR'),
    ('${THIRD}',     'Count Third',     'Chicago, IL',  41.8781,  -87.6298, 'America/Chicago',     'US', 'IL');
  insert into public.correspondents (requester_id, addressee_id, status, responded_at) values
    ('${SENDER}', '${RECIPIENT}', 'accepted', now()),
    ('${SENDER}', '${THIRD}',     'accepted', now());

  -- ${DELIVERED} letters the recipient may legitimately see.
  insert into public.letters (
    sender_id, recipient_id, body, state, written_at, collect_at, collected_at,
    postmark_date, transit_days, delivery_date, deliver_at, delivered_at,
    sender_tz, recipient_tz, schedule_source
  )
  select '${SENDER}', '${RECIPIENT}', 'Delivered ' || g, 'delivered',
         now() - interval '40 days', now() - interval '40 days', now() - interval '40 days',
         (now() - interval '40 days')::date, 3,
         ((now() - interval '30 days') at time zone 'America/Los_Angeles')::date,
         now() - interval '30 days', now() - interval '30 days',
         'America/New_York', 'America/Los_Angeles', 'count-fixture'
  from generate_series(1, ${DELIVERED}) g;

  -- ${IN_FLIGHT} letter that must not be knowable in any form.
  insert into public.letters (
    sender_id, recipient_id, body, state, written_at, collect_at, collected_at,
    postmark_date, transit_days, delivery_date, deliver_at,
    sender_tz, recipient_tz, schedule_source
  )
  select '${SENDER}', '${RECIPIENT}', 'Still in the air ' || g, 'in_transit',
         now() - interval '1 day', now() - interval '1 day', now() - interval '1 day',
         (now() - interval '1 day')::date, 4,
         ((now() + interval '4 days') at time zone 'America/Los_Angeles')::date,
         now() + interval '4 days',
         'America/New_York', 'America/Los_Angeles', 'count-fixture'
  from generate_series(1, ${IN_FLIGHT}) g;

  -- An unrelated third party's mail, so a whole-table estimate is
  -- distinguishable from a recipient-scoped one.
  insert into public.letters (
    sender_id, recipient_id, body, state, written_at, collect_at, collected_at,
    postmark_date, transit_days, delivery_date, deliver_at, delivered_at,
    sender_tz, recipient_tz, schedule_source
  )
  select '${SENDER}', '${THIRD}', 'Third party ' || g, 'delivered',
         now() - interval '40 days', now() - interval '40 days', now() - interval '40 days',
         (now() - interval '40 days')::date, 3,
         ((now() - interval '30 days') at time zone 'America/Los_Angeles')::date,
         now() - interval '30 days', now() - interval '30 days',
         'America/New_York', 'America/Chicago', 'count-fixture'
  from generate_series(1, ${THIRD_PARTY_LETTERS}) g;

  analyze public.letters;
  analyze public.profiles;
  analyze public.correspondents;
  analyze public.devices;
`);

const totalRows = Number(await psql(`select count(*) from public.letters;`));
console.log(
  `fixture: ${DELIVERED} delivered + ${IN_FLIGHT} in transit for the recipient, ` +
    `${THIRD_PARTY_LETTERS} for an unrelated third party, ${totalRows} rows in the table\n`,
);

const recipientJwt = await mint(RECIPIENT, "authenticated");

const recipientJwtProbe = recipientJwt;

// 1. The table itself must not be answerable. Asserting on the status rather
//    than on a count, because a leak that returns an error string in both modes
//    would make any planned-vs-exact comparison pass while proving nothing.
console.log("direct table access:");
for (const mode of ["exact", "planned", "estimated"] as const) {
  const r = await countVia(recipientJwtProbe, mode, "letters?select=id");
  console.log(`  GET /letters count=${mode.padEnd(9)} -> http ${r.status}  ${r.total}`);
  ok(
    r.status === 403 || r.status === 404,
    `GET /letters with count=${mode} is refused outright (got http ${r.status})`,
  );
}
console.log();

// 2. The read path that replaced it returns the landed mail and nothing else.
const mailboxExact = await countVia(recipientJwtProbe, "exact", "rpc/mailbox?select=id");
console.log(`mailbox() count=exact -> ${mailboxExact.total} (http ${mailboxExact.status})`);
ok(
  mailboxExact.total === String(DELIVERED),
  `mailbox() returns the ${DELIVERED} letters that have landed`,
);

const inTransitVisible = await psql(`
  select count(*) from public.letters
  where recipient_id = '${RECIPIENT}' and (deliver_at is null or deliver_at > now());
`);
ok(
  Number(inTransitVisible) === IN_FLIGHT,
  `fixture really does hold ${IN_FLIGHT} undelivered letter(s) for the recipient, so there is something to leak`,
);

// 3. The property that actually matters, stated as a measurement rather than as
//    a comparison against a number I chose. Whatever any endpoint reports, it
//    must not MOVE when mail the recipient may not see is added. A count that
//    cannot change cannot carry information. This is what makes the test
//    survive PostgREST inventing another counting mode: it does not care how the
//    number is produced, only that it is deaf to hidden mail.
const surfaces: Array<[string, string]> = [
  ["mailbox()", "rpc/mailbox?select=id"],
  ["outbox()", "rpc/outbox?select=id"],
  ["profiles", "profiles?select=id"],
  ["devices", "devices?select=id"],
  ["correspondents", "correspondents?select=id"],
];

const before = new Map<string, string>();
for (const [label, resource] of surfaces) {
  const parts: string[] = [];
  for (const mode of ["exact", "planned", "estimated"] as const) {
    const r = await countVia(recipientJwtProbe, mode, resource);
    parts.push(`${mode}=${r.total}`);
  }
  before.set(label, parts.join(" "));
}

const HIDDEN = 40;
await psql(`
  insert into public.letters (
    sender_id, recipient_id, body, state, written_at, collect_at, collected_at,
    postmark_date, transit_days, delivery_date, deliver_at, sender_tz, recipient_tz, schedule_source
  )
  select '${SENDER}', '${RECIPIENT}', 'Hidden ' || g, 'in_transit',
         now() - interval '2 days', now() - interval '2 days', now() - interval '2 days',
         current_date - 2, 4,
         ((now() + interval '4 days') at time zone 'America/Los_Angeles')::date,
         now() + interval '4 days',
         'America/New_York', 'America/Los_Angeles', 'count-fixture'
  from generate_series(1, ${HIDDEN}) g;
  analyze public.letters;
  analyze public.profiles;
  analyze public.correspondents;
`);

console.log(`\nadded ${HIDDEN} more letters in the air for this recipient, then re-measured:\n`);
for (const [label, resource] of surfaces) {
  const parts: string[] = [];
  for (const mode of ["exact", "planned", "estimated"] as const) {
    const r = await countVia(recipientJwtProbe, mode, resource);
    parts.push(`${mode}=${r.total}`);
  }
  const after = parts.join(" ");
  const was = before.get(label)!;
  const moved = was !== after;
  console.log(`  ${label.padEnd(16)} before[ ${was} ]  after[ ${after} ]${moved ? "   <-- MOVED" : ""}`);
  ok(!moved, `${label} reports the same counts before and after ${HIDDEN} letters are put in the air`);
}

// 4. The private schema holding one row per queued notification must not be
//    addressable at all.
const outbox = await countVia(recipientJwtProbe, "exact", "push_outbox?select=id");
console.log(`\n  push_outbox -> http ${outbox.status} (private schema, not exposed)`);
ok(
  outbox.status === 404 || outbox.status === 403,
  `slowmail.push_outbox is not reachable over PostgREST (got http ${outbox.status})`,
);
console.log();

// Cleanup --------------------------------------------------------------------
await psql(`
  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where sender_id = '${SENDER}';
  alter table public.letters enable trigger letters_guard_write;
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}', '${THIRD}');
  analyze public.letters;
`);

console.log(`\n1..${results.length}`);
results.forEach(([pass, name], i) => console.log(`${pass ? "ok" : "not ok"} ${i + 1} - ${name}`));
if (results.some(([pass]) => !pass)) {
  console.log("\nFAIL: the count channel reveals more than RLS allows.");
  Deno.exit(1);
}
console.log("\nPASS: no count mode reveals more than the rows RLS allows.");
