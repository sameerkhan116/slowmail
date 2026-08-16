// What happens to a row that already holds a colliding zone.
//
// The constraint added in 20260816121700 would be worth little if it only bound
// rows written after it. The interesting case is the database that already has a
// profile saying 'CET' and a letter in the postbox carrying that zone in its
// frozen envelope -- that letter is the one whose cutoff is late, and it stays
// late until something rewrites it.
//
// This reconstructs that database (constraint dropped, legacy rows inserted),
// measures the lateness, re-applies the migration, and requires the rows to have
// been repaired rather than merely walled off. Everything runs inside a
// transaction that is rolled back, so the stack is unchanged afterwards.
//
//   deno run -A --config supabase/functions/deno.json \
//     supabase/tests/integration/timezone_legacy_repair.ts

import { nextCollection } from "@slowmail/mailclock";

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";
const MIGRATION = new URL("../../migrations/20260816121700_timezone_runtime_agreement.sql", import.meta.url);

const SENDER = "9a000000-0000-4000-8000-00000000ce01";
const RECIPIENT = "9a000000-0000-4000-8000-00000000ce02";
const WRITTEN = "2026-07-15T09:00:00Z";

async function psql(sql: string): Promise<{ out: string; code: number }> {
  const proc = new Deno.Command("docker", {
    args: ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres",
      "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const w = proc.stdin.getWriter();
  await w.write(new TextEncoder().encode(sql));
  await w.close();
  const r = await proc.output();
  const dec = new TextDecoder();
  return { out: dec.decode(r.stdout) + dec.decode(r.stderr), code: r.code };
}

let passed = 0;
let failed = 0;
function check(name: string, ok: boolean, detail = "") {
  if (ok) {
    passed++;
    console.log(`ok ${passed + failed} - ${name}`);
  } else {
    failed++;
    console.error(`not ok ${passed + failed} - ${name}${detail ? ` (${detail})` : ""}`);
  }
}

const migrationSql = await Deno.readTextFile(MIGRATION);

// A database as it stood before the migration: no constraint, legacy zones in
// place, and a letter already in the postbox carrying one in its envelope.
const setup = `
begin;
alter table public.profiles drop constraint if exists profiles_timezone_is_region_city;
create or replace function slowmail.assert_valid_timezone() returns trigger language plpgsql as $legacy$
begin return new; end;
$legacy$;

insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}');
insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code)
values ('${SENDER}', 'Sender', 'Paris', 48.8566, 2.3522, 'CET', 'FR'),
       ('${RECIPIENT}', 'Recipient', 'Tokyo', 35.6762, 139.6503, 'Japan', 'JP');

insert into public.letters (id, sender_id, recipient_id, body, state, written_at,
                            collect_at, sender_tz, sender_lat, sender_lng, sender_country_code,
                            recipient_tz, recipient_lat, recipient_lng, recipient_country_code)
values ('9a000000-0000-4000-8000-00000000ce03', '${SENDER}', '${RECIPIENT}', 'in the postbox',
        'awaiting_collection', '${WRITTEN}',
        slowmail.next_collection_cutoff('CET', '${WRITTEN}'),
        'CET', 48.8566, 2.3522, 'FR', 'Asia/Tokyo', 35.6762, 139.6503, 'JP');

select 'before|'
  || (select timezone from public.profiles where id = '${SENDER}') || '|'
  || (select timezone from public.profiles where id = '${RECIPIENT}') || '|'
  || (select sender_tz from public.letters where id = '9a000000-0000-4000-8000-00000000ce03') || '|'
  || to_char((select collect_at from public.letters where id = '9a000000-0000-4000-8000-00000000ce03') at time zone 'UTC',
             'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
`;

const after = `
select 'after|'
  || (select timezone from public.profiles where id = '${SENDER}') || '|'
  || (select timezone from public.profiles where id = '${RECIPIENT}') || '|'
  || (select sender_tz from public.letters where id = '9a000000-0000-4000-8000-00000000ce03') || '|'
  || to_char((select collect_at from public.letters where id = '9a000000-0000-4000-8000-00000000ce03') at time zone 'UTC',
             'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');

-- The rule has to bind again once the repair is done.
savepoint probe;
do $probe$
begin
  insert into auth.users (id) values ('9a000000-0000-4000-8000-00000000ce09');
  insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code)
  values ('9a000000-0000-4000-8000-00000000ce09', 'Late', 'Berlin', 52.52, 13.405, 'CET', 'DE');
  raise notice 'REJECTED=no';
exception when others then
  raise notice 'REJECTED=yes';
end;
$probe$;
rollback to savepoint probe;
rollback;
`;

const res = await psql(setup + migrationSql + after);
if (res.code !== 0) {
  console.error(`the reconstruction could not run:\n${res.out}`);
  Deno.exit(1);
}

const before = res.out.split("\n").find((l) => l.startsWith("before|"))?.split("|");
const now = res.out.split("\n").find((l) => l.startsWith("after|"))?.split("|");
if (!before || !now) {
  console.error(`could not read the before/after rows:\n${res.out}`);
  Deno.exit(1);
}

const engineAt = nextCollection(WRITTEN, "Europe/Paris").at;

check("the reconstruction really did store the legacy zones", before[1] === "CET" && before[2] === "Japan",
  `profile zones were ${before[1]}, ${before[2]}`);
check("the legacy cutoff was later than the engine's, which is the bug",
  Date.parse(before[4]) > Date.parse(engineAt),
  `sql ${before[4]} vs engine ${engineAt}`);

check("the migration rewrote the profile rather than stranding it", now[1] === "Europe/Paris",
  `timezone is now ${now[1]}`);
check("a legacy country link is rewritten too", now[2] === "Asia/Tokyo", `timezone is now ${now[2]}`);
check("the letter's frozen sender zone was repaired", now[3] === "Europe/Paris", `sender_tz is now ${now[3]}`);
check("the letter's collect_at was recomputed and is no longer late",
  Date.parse(now[4]) <= Date.parse(engineAt),
  `sql ${now[4]} vs engine ${engineAt}`);
check("the constraint binds again afterwards", res.out.includes("REJECTED=yes"));

console.log("");
if (failed > 0) {
  console.error(`FAIL: ${failed} of ${passed + failed} checks failed; a pre-existing legacy zone survives the migration.`);
  Deno.exit(1);
}
console.log(`PASS: legacy zones already in the database are repaired, not merely forbidden (${passed} checks).`);
