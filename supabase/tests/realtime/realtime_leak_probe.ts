// Empirical check that Realtime cannot be used as an early-warning channel.
//
// The database tests assert structurally that `public.letters` is absent from the
// `supabase_realtime` publication. That is necessary but not sufficient evidence:
// "no events arrived" is also what a broken probe looks like. So this probe
// subscribes to two tables at once — `public.letters` and a throwaway control
// table that IS published — and requires the control event to arrive. If the
// control is silent the probe reports INCONCLUSIVE rather than success.
//
// Run against a running local stack:
//   deno run -A supabase/tests/realtime/realtime_leak_probe.ts

import { createClient } from "npm:@supabase/supabase-js@2";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const API_URL = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
// The Supabase CLI's published default for `supabase start`, identical on every
// developer machine. It is a local test constant, not a credential; a deployed
// project has its own secret and this probe is not meant to run against one.
const JWT_SECRET = Deno.env.get("SUPABASE_JWT_SECRET") ??
  "super-secret-jwt-token-with-at-least-32-characters-long";
const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";

const SENDER = "31111111-0000-4000-8000-000000000001";
const RECIPIENT = "31111111-0000-4000-8000-000000000002";
const LETTER = "3a000000-0000-4000-8000-000000000001";
const CONTROL_ROW = "3c000000-0000-4000-8000-000000000001";

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
    args: ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-q", "-v", "ON_ERROR_STOP=1"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const w = p.stdin.getWriter();
  await w.write(new TextEncoder().encode(sql));
  await w.close();
  const out = await p.output();
  const stderr = new TextDecoder().decode(out.stderr);
  if (!out.success) throw new Error(`psql failed:\n${stderr}`);
  return new TextDecoder().decode(out.stdout);
}

const results: Array<[boolean, string]> = [];
const ok = (pass: boolean, name: string) => results.push([pass, name]);

await psql(`
  drop table if exists public.rt_control;
  create table public.rt_control (
    id uuid primary key,
    recipient_id uuid not null,
    note text not null
  );
  alter table public.rt_control enable row level security;
  alter table public.rt_control replica identity full;
  create policy rt_control_select on public.rt_control for select to authenticated using (true);
  grant select on public.rt_control to authenticated;
  alter publication supabase_realtime add table public.rt_control;

  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where id = '${LETTER}';
  alter table public.letters enable trigger letters_guard_write;
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}');

  insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}');
  insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code, region) values
    ('${SENDER}', 'Realtime Sender', 'New York, NY', 40.7128, -74.0060, 'America/New_York', 'US', 'NY'),
    ('${RECIPIENT}', 'Realtime Recipient', 'Los Angeles, CA', 34.0522, -118.2437, 'America/Los_Angeles', 'US', 'CA');
  insert into public.correspondents (requester_id, addressee_id, status, responded_at)
    values ('${SENDER}', '${RECIPIENT}', 'accepted', now());
`);

const anonJwt = await mint(null, "anon");
const recipientJwt = await mint(RECIPIENT, "authenticated");

const client = createClient(API_URL, anonJwt, {
  realtime: { params: { eventsPerSecond: 20 } },
  auth: { persistSession: false, autoRefreshToken: false },
});
await client.realtime.setAuth(recipientJwt);

let letterEvents = 0;
let controlEvents = 0;

const subscribed = (name: string, table: string, onEvent: () => void) =>
  new Promise<void>((resolve, reject) => {
    client
      .channel(name)
      .on("postgres_changes", { event: "*", schema: "public", table }, onEvent)
      .subscribe((status: string, err?: Error) => {
        if (status === "SUBSCRIBED") resolve();
        if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
          reject(err ?? new Error(`${table}: ${status}`));
        }
      });
  });

// A subscription to an unpublished table is not itself an error — the server
// accepts the topic and simply never sends anything. That is the shape of the
// leak we are ruling out, so we tolerate a failed join here and let the
// event counter be the verdict.
try {
  await subscribed("probe-letters", "letters", () => letterEvents++);
  ok(true, "realtime accepted a subscription to public.letters (worst case for us)");
} catch (e) {
  ok(true, `realtime refused a subscription to public.letters: ${(e as Error).message}`);
}
await subscribed("probe-control", "rt_control", () => controlEvents++);

await new Promise((r) => setTimeout(r, 1500));

// Both writes happen in one transaction so neither can be dismissed as a timing artefact.
await psql(`
  begin;
  insert into public.letters (id, sender_id, recipient_id, body, state, written_at, collect_at)
    values ('${LETTER}', '${SENDER}', '${RECIPIENT}', 'Realtime must never reveal this.',
            'awaiting_collection', now() - interval '2 hours', now() - interval '1 hour');
  -- The collection transition: this is the moment the row gains a deliver_at in
  -- the future, and the moment a leaky publication would page the recipient.
  update public.letters set
    state = 'in_transit', collected_at = now(), postmark_date = current_date, transit_days = 4,
    deliver_at = now() + interval '4 days',
    delivery_date = ((now() + interval '4 days') at time zone 'America/Los_Angeles')::date,
    sender_tz = 'America/New_York', sender_lat = 40.7128, sender_lng = -74.0060,
    sender_country_code = 'US', sender_is_territory = false,
    recipient_tz = 'America/Los_Angeles', recipient_lat = 34.0522, recipient_lng = -118.2437,
    recipient_country_code = 'US', schedule_source = 'realtime-probe'
  where id = '${LETTER}';
  insert into public.rt_control (id, recipient_id, note) values ('${CONTROL_ROW}', '${RECIPIENT}', 'control');
  commit;
`);

await new Promise((r) => setTimeout(r, 6000));

ok(controlEvents > 0, `control: realtime delivered ${controlEvents} event(s) on a published table, so the probe works`);
ok(letterEvents === 0, `letters: realtime delivered ${letterEvents} event(s) for an undelivered letter`);

await client.removeAllChannels();
await client.realtime.disconnect();

await psql(`
  alter publication supabase_realtime drop table public.rt_control;
  drop table public.rt_control;
  alter table public.letters disable trigger letters_guard_write;
  delete from public.letters where id = '${LETTER}';
  alter table public.letters enable trigger letters_guard_write;
  delete from auth.users where id in ('${SENDER}', '${RECIPIENT}');
`);

console.log(`1..${results.length}`);
results.forEach(([pass, name], i) => console.log(`${pass ? "ok" : "not ok"} ${i + 1} - ${name}`));

if (!results[results.length - 2][0]) {
  console.error("\nINCONCLUSIVE: the control table produced no events, so silence on letters proves nothing.");
  Deno.exit(2);
}
if (results.some(([pass]) => !pass)) Deno.exit(1);
console.log("\nPASS: realtime is a working channel here, and it carries nothing about undelivered letters.");
