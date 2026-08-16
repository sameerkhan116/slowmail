// Puerto Rico is a data-modelling hazard, not an engine bug.
//
// The spec puts AK, HI and PR in the far domestic band at 5 days, and genuine
// territories (Guam, APO/FPO) at 7. mailclock reads isTerritory before it looks
// at the region, so a profile that sets both region = 'PR' and
// is_territory = true routes at 7 and is silently a day and a half wrong in the
// direction the user notices. The engine is right -- Guam really is 7 -- so the
// fix belongs in what the database will let a profile say.
//
// This asserts both halves, because either alone can pass while the product is
// broken: that the engine gives PR 5 days when the profile is shaped correctly,
// and that the database refuses to store the shape that would make it 7.
//
// A missing region is the quieter version of the same bug: Anchorage routed on
// raw distance alone comes out at 4, which is plausible enough that nobody
// files it.
//
//   deno test -A --config supabase/functions/deno.json supabase/tests/integration/zone_bands.ts

import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { baseDomesticTransitDays, haversineMiles, schedule } from "../../functions/_shared/mailclock.ts";

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";

async function psql(sql: string): Promise<{ out: string; code: number }> {
  const p = new Deno.Command("docker", {
    args: ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres",
           "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const w = p.stdin.getWriter();
  await w.write(new TextEncoder().encode(sql));
  await w.close();
  const r = await p.output();
  const out = new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr);
  // A test that cannot reach the stack must fail, not report that it found
  // nothing wrong.
  if (r.code !== 0 && !/ERROR:/.test(out)) {
    throw new Error(`could not reach the database (exit ${r.code}): ${out.trim()}`);
  }
  return { out: out.trim(), code: r.code };
}

const NYC = { tz: "America/New_York", lat: 40.7128, lng: -74.006, countryCode: "US", region: "NY" };
const WRITTEN = "2026-03-10T15:00:00.000Z";

// The band, not a sample. schedule() adds a deterministic +/-1 day of jitter,
// so PR done right (5) and PR done wrong (7) produce overlapping observations
// at 6 and no single letter can tell them apart. The band is the thing the
// spec fixes, so the band is what gets asserted -- with a separate check that
// the end-to-end schedule stays within one day of it.
function band(recipient: Record<string, unknown>): number {
  // deno-lint-ignore no-explicit-any
  return baseDomesticTransitDays(haversineMiles(NYC.lat, NYC.lng, recipient.lat as number, recipient.lng as number), NYC as any, recipient as any);
}

function jitteredTransit(recipient: Record<string, unknown>, messageId: string): number {
  return schedule({
    messageId,
    writtenAt: WRITTEN,
    sender: NYC,
    // deno-lint-ignore no-explicit-any
    recipient: recipient as any,
  }).transitDays;
}

const SAN_JUAN = { tz: "America/Puerto_Rico", lat: 18.4655, lng: -66.1057, countryCode: "US", userId: "u-pr" };
const ANCHORAGE = { tz: "America/Anchorage", lat: 61.2181, lng: -149.9003, countryCode: "US", userId: "u-ak" };
const HONOLULU = { tz: "Pacific/Honolulu", lat: 21.3069, lng: -157.8583, countryCode: "US", userId: "u-hi" };
const GUAM = { tz: "Pacific/Guam", lat: 13.4443, lng: 144.7937, countryCode: "US", userId: "u-gu" };

Deno.test("Puerto Rico routes at 5 days when it is not marked a territory", () => {
  assertEquals(band({ ...SAN_JUAN, region: "PR", isTerritory: false }), 5);
});

Deno.test("marking Puerto Rico a territory is what breaks it", () => {
  // Not a wish for different engine behaviour -- this is the misroute the
  // database constraint exists to make unstorable.
  assertEquals(band({ ...SAN_JUAN, region: "PR", isTerritory: true }), 7);
});

Deno.test("Alaska and Hawaii are far-zone on their region, not their distance", () => {
  assertEquals(band({ ...ANCHORAGE, region: "AK" }), 5);
  assertEquals(band({ ...HONOLULU, region: "HI" }), 5);
  // Distance alone would put Anchorage in the 1801+ band anyway, so the case
  // that proves the region is doing the work is the one where it is missing.
  assertEquals(band({ ...HONOLULU }), 5);
  assertEquals(band({ ...SAN_JUAN }), 4);
});

Deno.test("a genuine territory still routes at 7", () => {
  assertEquals(band({ ...GUAM, region: "GU", isTerritory: true }), 7);
});

Deno.test("the end-to-end schedule stays within a day of its band", () => {
  const pr = { ...SAN_JUAN, region: "PR", isTerritory: false };
  for (let i = 0; i < 40; i++) {
    const days = jitteredTransit(pr, `0000000${i}-0000-4000-8000-0000000000aa`.slice(-36));
    if (Math.abs(days - 5) > 1) {
      throw new Error(`transit ${days} is more than one day off the 5-day band`);
    }
  }
});

Deno.test("the database refuses to store a Puerto Rico territory profile", async () => {
  const { out, code } = await psql(`
    begin;
    insert into auth.users (id) values ('9a000000-0000-4000-8000-0000000000a1');
    insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng,
                                 timezone, country_code, region, is_territory)
    values ('9a000000-0000-4000-8000-0000000000a1', 'PR', 'San Juan', 18.4655, -66.1057,
            'America/Puerto_Rico', 'US', 'PR', true);
    rollback;`);
  if (code === 0) throw new Error(`expected the insert to be rejected, got:\n${out}`);
  assertStringIncludes(out, "profiles_territory_excludes_states");
});

Deno.test("the database refuses a US profile with no region", async () => {
  const { out, code } = await psql(`
    begin;
    insert into auth.users (id) values ('9a000000-0000-4000-8000-0000000000a2');
    insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng,
                                 timezone, country_code)
    values ('9a000000-0000-4000-8000-0000000000a2', 'AK', 'Anchorage', 61.2181, -149.9003,
            'America/Anchorage', 'US');
    rollback;`);
  if (code === 0) throw new Error(`expected the insert to be rejected, got:\n${out}`);
  assertStringIncludes(out, "profiles_us_requires_region");
});

Deno.test("a correctly shaped Puerto Rico profile is storable", async () => {
  const { out, code } = await psql(`
    begin;
    insert into auth.users (id) values ('9a000000-0000-4000-8000-0000000000a3');
    insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng,
                                 timezone, country_code, region, is_territory)
    values ('9a000000-0000-4000-8000-0000000000a3', 'PR', 'San Juan', 18.4655, -66.1057,
            'America/Puerto_Rico', 'US', 'PR', false);
    rollback;`);
  if (code !== 0) throw new Error(`the supported shape was rejected:\n${out}`);
});
