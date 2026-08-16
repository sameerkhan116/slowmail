// Every timezone a profile can hold, checked on the days where the two runtimes
// can disagree.
//
// `collection_cutoff_bound.ts` proves the never-late property against the
// contract fixtures, but those fixtures only ever use America/New_York and
// Asia/Tokyo. That samples the property; it does not establish it. The
// disagreement that matters is per-zone, so the sweep has to be per-zone.
//
// What it is looking for: Postgres resolves a timezone string against its
// abbreviation table before its zone table, so `AT TIME ZONE 'CET'` is a fixed
// +01:00 all year. Luxon reads the same string as a DST-observing zone. In
// European summer the two are an hour apart, and the SQL cutoff lands *later*
// than the engine's -- the one direction the cutoff is not allowed to take,
// because a letter past its authoritative collection instant is still
// `awaiting_collection` and so still revocable. The sender can reach back into
// the postbox for an hour after five o'clock has already passed.
//
// Every zone is swept rather than a chosen few, because the next collision will
// not be named CET. Dates are chosen adversarially per zone -- its own DST
// transitions and the days either side -- rather than uniformly, since a
// year-long sweep of every zone is slow and the interior of a zone's offset
// period holds nothing a transition day does not.
//
//   deno run -A --config supabase/functions/deno.json \
//     supabase/tests/integration/timezone_agreement.ts

import { DateTime } from "luxon";
import { nextCollection } from "@slowmail/mailclock";

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";
const YEAR = 2026;

// Times of day are local to the zone under test and sit either side of the
// 17:00 cutoff, which is where a one-hour offset error changes the answer.
const LOCAL_TIMES: [number, number][] = [[9, 0], [16, 59], [17, 1], [23, 30]];

const lit = (v: string) => `'${v.replaceAll("'", "''")}'`;

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

// The zones a profile will actually accept, established by trying to store each
// one rather than by restating the rule here. A sweep that keeps its own copy of
// the constraint drifts from it silently; this one cannot, because when the
// constraint changes the set of probes changes with it.
const zoneQuery = `
  do $$
  declare
    v_name text;
    v_user uuid := '9a000000-0000-4000-8000-00000000fa11';
  begin
    create temporary table accepted_zones (name text) on commit drop;
    insert into auth.users (id) values (v_user) on conflict do nothing;
    for v_name in select name from pg_catalog.pg_timezone_names order by name loop
      begin
        insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng,
                                     timezone, country_code, region)
        values (v_user, 'sweep', 'sweep', 40.0, -74.0, v_name, 'US', 'NY');
        insert into accepted_zones (name) values (v_name);
        delete from public.profiles where id = v_user;
      exception when others then
        null;
      end;
    end loop;
  end;
  $$;
  select name from accepted_zones order by name;
`;
const zoneRes = await psql(`begin; ${zoneQuery} rollback;`);
if (zoneRes.code !== 0) {
  console.error(`could not reach the database:\n${zoneRes.out}`);
  Deno.exit(1);
}
const allZones = zoneRes.out.trim().split("\n").map((z) => z.trim()).filter(Boolean);
if (allZones.length < 100) {
  console.error(`only ${allZones.length} zones came back; the sweep would prove nothing`);
  Deno.exit(2);
}

// Zones the constraint accepts *and* the engine can use. A zone Luxon rejects
// outright is a different bug, reported separately below rather than folded in.
const zones: string[] = [];
const engineRejects: string[] = [];
for (const z of allZones) {
  if (DateTime.now().setZone(z).isValid) zones.push(z);
  else engineRejects.push(z);
}

/** The days in YEAR where this zone changes offset, plus the days either side. */
function adversarialDates(zone: string): string[] {
  const dates = new Set<string>([`${YEAR}-01-15`, `${YEAR}-07-15`]);
  let cursor = DateTime.fromISO(`${YEAR}-01-01T12:00:00`, { zone });
  let prev = cursor.offset;
  for (let i = 1; i < 366; i++) {
    const day = cursor.plus({ days: i });
    if (!day.isValid) continue;
    if (day.offset !== prev) {
      for (const d of [-1, 0, 1]) {
        const around = day.plus({ days: d });
        if (around.isValid) dates.add(around.toISODate()!);
      }
      prev = day.offset;
    }
  }
  return [...dates];
}

type Probe = { zone: string; writtenAt: string; date: string; local: string };

const probes: Probe[] = [];
for (const zone of zones) {
  for (const date of adversarialDates(zone)) {
    for (const [h, m] of LOCAL_TIMES) {
      const local = DateTime.fromISO(`${date}T${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:00`, { zone });
      // A local time inside a spring-forward gap does not exist. Luxon snaps it
      // forward; that is a real instant and still worth probing.
      if (!local.isValid) continue;
      probes.push({ zone, writtenAt: local.toUTC().toISO()!, date, local: `${h}:${String(m).padStart(2, "0")}` });
    }
  }
}

if (probes.length < 1000) {
  console.error(`only ${probes.length} probes were generated; the sweep would prove nothing`);
  Deno.exit(2);
}

// Chunked so the generated VALUES list stays a size Postgres will parse.
const CHUNK = 2000;
const sqlCutoffs: string[] = [];
for (let i = 0; i < probes.length; i += CHUNK) {
  const chunk = probes.slice(i, i + CHUNK);
  const q = `
    with probes (i, tz, written_at) as (values
      ${chunk.map((p, j) => `(${j}, ${lit(p.zone)}, ${lit(p.writtenAt)}::timestamptz)`).join(",\n      ")}
    )
    select to_char(slowmail.next_collection_cutoff(tz, written_at) at time zone 'UTC',
                   'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    from probes order by i;`;
  const res = await psql(q);
  if (res.code !== 0) {
    console.error(`the cutoff query failed:\n${res.out}`);
    Deno.exit(1);
  }
  const rows = res.out.trim().split("\n").map((r) => r.trim()).filter(Boolean);
  if (rows.length !== chunk.length) {
    console.error(`asked for ${chunk.length} cutoffs and got ${rows.length}; refusing to compare`);
    Deno.exit(1);
  }
  sqlCutoffs.push(...rows);
}

type Violation = { zone: string; writtenAt: string; local: string; sql: string; engine: string; lateBy: number };
const late: Violation[] = [];
const engineThrew: { zone: string; error: string }[] = [];
let compared = 0;

for (let i = 0; i < probes.length; i++) {
  const p = probes[i];
  let engineAt: string;
  try {
    engineAt = nextCollection(p.writtenAt, p.zone).at;
  } catch (e) {
    engineThrew.push({ zone: p.zone, error: String(e).slice(0, 80) });
    continue;
  }
  compared++;
  const sqlMs = Date.parse(sqlCutoffs[i]);
  const engMs = Date.parse(engineAt);
  if (sqlMs > engMs) {
    late.push({
      zone: p.zone,
      writtenAt: p.writtenAt,
      local: p.local,
      sql: sqlCutoffs[i],
      engine: engineAt,
      lateBy: (sqlMs - engMs) / 60000,
    });
  }
}

if (compared === 0) {
  console.error("nothing was actually compared; the sweep proves nothing");
  Deno.exit(2);
}

const lateZones = [...new Set(late.map((v) => v.zone))].sort();

console.log(`swept ${zones.length} zones over ${probes.length} probes (${compared} compared)`);
if (engineRejects.length > 0) {
  console.log(`  ${engineRejects.length} zones the database accepts are not valid to the engine: ${engineRejects.slice(0, 8).join(", ")}`);
}
if (engineThrew.length > 0) {
  console.log(`  ${engineThrew.length} probes threw in the engine`);
}

if (late.length > 0) {
  console.error(`\nnot ok - the SQL cutoff runs LATE in ${lateZones.length} zones (${late.length} probes)`);
  console.error(`zones: ${lateZones.join(", ")}`);
  for (const v of late.slice(0, 6)) {
    console.error(`  ${v.zone} written ${v.writtenAt} (${v.local} local): sql ${v.sql} vs engine ${v.engine} -- late by ${v.lateBy} min`);
  }
  console.error(
    `\nFAIL: a letter stays awaiting_collection past its authoritative collection instant in these zones, so it stays revocable after the post has gone.`,
  );
  Deno.exit(1);
}

for (const z of [...new Set([...engineRejects])]) {
  console.error(`not ok - the database accepts ${z} but the engine cannot use it`);
}
if (engineRejects.length > 0 || engineThrew.length > 0) {
  console.error("\nFAIL: a profile can hold a zone that wedges its owner's mail.");
  Deno.exit(1);
}

console.log(`\nPASS: across ${zones.length} zones and ${probes.length} probes the SQL cutoff is never later than the engine's.`);
