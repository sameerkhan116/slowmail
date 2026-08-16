// Is slowmail_reader's attribute set load-bearing, and does the migration
// actually enforce it?
//
// slowmail_reader is the only thing keeping the mailbox functions subject to
// RLS. They are SECURITY DEFINER, so whatever that role is allowed to do, every
// recipient is allowed to do. A slowmail_reader carrying BYPASSRLS -- one that
// existed on the database before these migrations ran, say -- would hand every
// recipient their undelivered mail, and no policy, trigger or grant in this
// repo would notice.
//
// So this does not assert a catalog bit and call it a day. It weakens the role,
// measures the leak, re-runs the migration, and measures it gone. If the
// normalisation were removed, step 4 would stay leaking and this goes red.
//
// It also measures the same thing as postgres throughout, because that is the
// trap: postgres carries BYPASSRLS already, so an assertion written that way
// reads identically whether the hold is on or off. That comparison is asserted
// here rather than left as a warning in a comment.
//
//   deno run -A --config supabase/functions/deno.json \
//     supabase/tests/integration/reader_role_hardening.ts

const DB_CONTAINER = Deno.env.get("SLOWMAIL_DB_CONTAINER") ?? "supabase_db_slowmail";
const MIGRATION = "supabase/migrations/20260816121500_unexpose_letters_table.sql";

const SENDER = "51111111-0000-4000-8000-000000000001";
const RECIPIENT = "51111111-0000-4000-8000-000000000002";
const LETTER = "5a000000-0000-4000-8000-000000000001";

async function psql(sql: string, withNotices = false): Promise<string> {
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
  const out = await p.output();
  const stderr = new TextDecoder().decode(out.stderr);
  // Unreachable stack is a failure, never a quiet pass.
  if (!out.success) throw new Error(`psql failed:\n${stderr}`);
  const stdout = new TextDecoder().decode(out.stdout);
  // Warnings arrive on stderr, so a test that reads only stdout would report a
  // silent adoption as if it had been announced.
  return (withNotices ? stdout + stderr : stdout).trim();
}

const results: Array<[boolean, string]> = [];
const ok = (pass: boolean, name: string) => results.push([pass, name]);

/** What the recipient can see, asked as the role the mailbox functions run as. */
const asReader = () => psql(`
  begin;
  set local request.jwt.claims = '{"sub":"${RECIPIENT}","role":"authenticated"}';
  set local role slowmail_reader;
  select count(*) from public.letters;
  rollback;
`);

const asPostgres = () => psql(`select count(*) from public.letters where id = '${LETTER}';`);

const attributes = () => psql(`
  select rolcanlogin::text || ',' || rolbypassrls::text || ',' || rolsuper::text || ',' ||
         rolinherit::text || ',' || rolcreaterole::text || ',' || rolreplication::text
  from pg_roles where rolname = 'slowmail_reader';
`);

async function cleanup() {
  await psql(`
    alter role slowmail_reader nologin noinherit nobypassrls nocreaterole nocreatedb noreplication;
    alter table public.letters disable trigger letters_guard_write;
    delete from public.letters where id = '${LETTER}';
    alter table public.letters enable trigger letters_guard_write;
    delete from auth.users where id in ('${SENDER}', '${RECIPIENT}');
  `);
}

try {
  await psql(`
    alter table public.letters disable trigger letters_guard_write;
    delete from public.letters where id = '${LETTER}';
    alter table public.letters enable trigger letters_guard_write;
    delete from auth.users where id in ('${SENDER}', '${RECIPIENT}');

    insert into auth.users (id) values ('${SENDER}'), ('${RECIPIENT}');
    insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code, region) values
      ('${SENDER}',    'Hardening Sender',    'Brooklyn, NY', 40.6782,  -73.9442, 'America/New_York',    'US', 'NY'),
      ('${RECIPIENT}', 'Hardening Recipient', 'Portland, OR', 45.5152, -122.6784, 'America/Los_Angeles', 'US', 'OR');
    insert into public.correspondents (requester_id, addressee_id, status, responded_at)
      values ('${SENDER}', '${RECIPIENT}', 'accepted', now());

    -- One letter, in transit, addressed to the recipient. It must not exist for
    -- them until it lands.
    insert into public.letters (
      id, sender_id, recipient_id, body, state, written_at, collect_at, collected_at,
      postmark_date, transit_days, deliver_at, sender_tz, recipient_tz, schedule_source
    ) values (
      '${LETTER}', '${SENDER}', '${RECIPIENT}', 'Still in the air.', 'in_transit',
      now() - interval '2 days', now() - interval '2 days', now() - interval '2 days',
      (now() - interval '2 days')::date, 4, now() + interval '4 days',
      'America/New_York', 'America/Los_Angeles', 'test-fixture'
    );
  `);

  // 1. The shipped state.
  const shipped = await attributes();
  ok(
    shipped === "false,false,false,false,false,false",
    `slowmail_reader ships with no dangerous attribute (login,bypassrls,super,inherit,createrole,replication = ${shipped})`,
  );

  const heldBefore = await asReader();
  ok(heldBefore === "0", `the recipient sees ${heldBefore} letters while it is in transit`);

  // Control: the row is really there, so a zero above means filtered, not empty.
  const reallyThere = await asPostgres();
  ok(reallyThere === "1", `the letter really is in the table (${reallyThere} row)`);

  // 2. Weaken the role exactly as a pre-existing one might have been.
  await psql(`alter role slowmail_reader bypassrls;`);

  const leaked = await asReader();
  ok(
    leaked === "1",
    `BYPASSRLS on slowmail_reader discloses the undelivered letter (recipient now sees ${leaked}), so the attribute is load-bearing`,
  );

  // 3. The trap, stated as a measurement. postgres reads the same number in
  //    both states, so an assertion written as postgres cannot tell a hold that
  //    works from one that has been switched off.
  const postgresWhileLeaking = await asPostgres();
  ok(
    postgresWhileLeaking === reallyThere,
    `asked as postgres the count is ${postgresWhileLeaking} either way, so only a reader-role assertion can see this`,
  );

  // 4. Re-running the migration has to put it back.
  const migration = await Deno.readTextFile(MIGRATION);
  const output = await psql(migration, true);
  ok(
    /slowmail_reader already existed with .*BYPASSRLS/.test(output),
    "re-running the migration reports the adopted role rather than fixing it silently",
  );

  const repaired = await attributes();
  ok(repaired === shipped, `the migration restores the attributes (${repaired})`);

  const heldAfter = await asReader();
  ok(heldAfter === "0", `the recipient is back to seeing ${heldAfter} letters`);
} finally {
  await cleanup();
}

console.log(`1..${results.length}`);
results.forEach(([pass, name], i) => console.log(`${pass ? "ok" : "not ok"} ${i + 1} - ${name}`));
if (results.some(([pass]) => !pass)) {
  console.error("\nFAIL: the reader role is not being held to the attributes the hold depends on.");
  Deno.exit(1);
}
console.log("\nPASS: BYPASSRLS on the reader role leaks, and the migration takes it back off.");
