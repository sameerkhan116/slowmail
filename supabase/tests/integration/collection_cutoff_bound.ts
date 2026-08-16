// The only timing logic in SQL, checked against the fixtures rather than
// against expectations invented here.
//
// `slowmail.next_collection_cutoff` is deliberately not a port of the postal
// rules: it knows about 17:00 and nothing about Sundays or federal holidays. It
// exists so a posted letter has a cheap `collect_at` for the sweep to index on,
// and the engine's authoritative `collectedAt` replaces it at collection.
//
// That division is only safe if one property holds for every case in the
// contract: the SQL cutoff is never later than the real collection. Late means
// a letter sits in the postbox past its pickup, which is a bug users would see.
// Early only means the sweep looks at a letter, asks the engine and puts it
// back -- exactly what apply_collection's `future` branch does.
//
// The second assertion keeps the first honest. A cutoff of `-infinity` would
// satisfy "never late" while being useless, so each cutoff must also fall
// strictly after the letter was written.
//
//   deno run -A supabase/tests/integration/collection_cutoff_bound.ts

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";
const FIXTURES = new URL("../../../fixtures/mailclock-cases.json", import.meta.url);

type CollectionCase = {
  name: string;
  writtenAt: string;
  tz: string;
  postmarkDate: string;
  collectedAt: string;
};

const lit = (v: string) => `'${v.replaceAll("'", "''")}'`;

const cases: CollectionCase[] = JSON.parse(await Deno.readTextFile(FIXTURES)).collection;
if (cases.length === 0) {
  console.error("no collection cases in the fixtures; nothing was checked");
  Deno.exit(2);
}

const sql = `
  with cases (i, written_at, tz) as (values
    ${cases.map((c, i) => `(${i}, ${lit(c.writtenAt)}::timestamptz, ${lit(c.tz)})`).join(",\n    ")}
  )
  select to_char(slowmail.next_collection_cutoff(tz, written_at) at time zone 'UTC',
                 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  from cases order by i;
`;

const proc = new Deno.Command("docker", {
  args: ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
  stdin: "piped",
  stdout: "piped",
  stderr: "piped",
}).spawn();
const writer = proc.stdin.getWriter();
await writer.write(new TextEncoder().encode(sql));
await writer.close();
const out = await proc.output();
if (!out.success) {
  console.error(new TextDecoder().decode(out.stderr));
  Deno.exit(1);
}

const cutoffs = new TextDecoder().decode(out.stdout).trim().split("\n").filter(Boolean);
if (cutoffs.length !== cases.length) {
  console.error(`expected ${cases.length} cutoffs, got ${cutoffs.length}`);
  Deno.exit(2);
}

const results: Array<[boolean, string]> = [];
cases.forEach((c, i) => {
  const cutoff = new Date(cutoffs[i]).getTime();
  const written = new Date(c.writtenAt).getTime();
  const collected = new Date(c.collectedAt).getTime();

  results.push([
    cutoff <= collected,
    `never late: ${c.name} — cutoff ${cutoffs[i]} <= collection ${c.collectedAt}`,
  ]);
  results.push([
    cutoff > written,
    `not vacuously early: ${c.name} — cutoff ${cutoffs[i]} > written ${c.writtenAt}`,
  ]);
});

console.log(`1..${results.length}`);
results.forEach(([pass, name], i) => console.log(`${pass ? "ok" : "not ok"} ${i + 1} - ${name}`));
if (results.some(([pass]) => !pass)) Deno.exit(1);
console.log(
  `\nPASS: across ${cases.length} contract cases the SQL cutoff never runs past the engine's collection instant.`,
);
