-- Close the count channel by taking the table off the API surface.
--
-- The policy was never wrong. The problem is that `public.letters` was reachable
-- over PostgREST at all, because PostgREST answers `Prefer: count=planned` from
-- the query planner's row estimate, and the planner estimates before RLS
-- filters. Measured on a reset stack, authenticated as the recipient, with one
-- letter in the air and nineteen delivered:
--
--   GET /letters                                   count=exact   -> 19
--   GET /letters                                   count=planned -> 27  (whole table)
--   GET /letters?recipient_id=eq.<self>            count=planned -> 20
--   GET /letters?recipient_id=eq.<self>
--       &deliver_at=gt.<future>                    count=exact   ->  0
--   GET /letters?recipient_id=eq.<self>
--       &deliver_at=gt.<future>                    count=planned ->  1
--
-- The last pair is the product failure. RLS answers "there is nothing", the
-- planner answers "there is one", and the number tracks the truth as it grows:
-- 1 -> 1, 3 -> 2, 9 -> 7, 25 -> 22. That is the badge we promised does not
-- exist. `count=estimated` is not a safer alternative, it is the same leak
-- behind a threshold: it returned the exact 19 only because 19 < db-max-rows,
-- and returned 27 as soon as the table was larger than the limit.
--
-- PostgREST has no setting that refuses count=planned, so the fix cannot be a
-- configuration flag. Removing SELECT removes the resource, which removes this
-- leak and every other feature PostgREST may later build on a readable table.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'slowmail_reader') then
    -- No login, no inherit, and deliberately not BYPASSRLS: this role reads
    -- letters through the same policies as everyone else. It is the role the
    -- mailbox functions execute as, which is what keeps RLS -- not a WHERE
    -- clause inside a function -- the thing enforcing the hold.
    create role slowmail_reader nologin noinherit;
  end if;
end;
$$;

-- Creating the role only when it is absent means a database that already has a
-- role of this name silently adopts it, whatever it is. That is the one
-- adoption that cannot be allowed to pass quietly: this role is the whole
-- reason the mailbox functions are still subject to RLS, so a pre-existing
-- slowmail_reader carrying BYPASSRLS would turn the hold off for every
-- recipient with nothing anywhere reporting it. The attributes are therefore
-- asserted rather than inferred from the create above.
--
-- NOSUPERUSER is not in the ALTER below because it cannot be: the migration
-- role here has CREATEROLE and BYPASSRLS but not SUPERUSER, and Postgres
-- refuses `alter role ... nosuperuser` from a non-superuser whatever the
-- target's attributes are. A superuser slowmail_reader is therefore
-- unrepairable from inside a migration, and is the one case that aborts.
do $$
declare
  v_bad text[];
begin
  if exists (select 1 from pg_roles where rolname = 'slowmail_reader' and rolsuper) then
    raise exception
      'slowmail_reader exists as a SUPERUSER and cannot be demoted from a migration. '
      'Refusing to continue: the mailbox functions would run as a role that bypasses '
      'every policy, which would disclose undelivered mail to its recipient.';
  end if;

  select array_agg(a) into v_bad
  from (
    select 'BYPASSRLS'  a from pg_roles where rolname = 'slowmail_reader' and rolbypassrls
    union all select 'LOGIN'       from pg_roles where rolname = 'slowmail_reader' and rolcanlogin
    union all select 'CREATEROLE'  from pg_roles where rolname = 'slowmail_reader' and rolcreaterole
    union all select 'CREATEDB'    from pg_roles where rolname = 'slowmail_reader' and rolcreatedb
    union all select 'REPLICATION' from pg_roles where rolname = 'slowmail_reader' and rolreplication
    union all select 'INHERIT'     from pg_roles where rolname = 'slowmail_reader' and rolinherit
  ) s;

  if v_bad is not null then
    -- A warning and a repair rather than an abort, and the direction matters.
    -- Aborting here would roll back this migration's `revoke all on
    -- public.letters`, leaving the table readable over the Data API and the
    -- planner-count leak open. Failing closed on the role would mean failing
    -- open on the thing the role exists to protect, so the attributes are
    -- corrected below and the surprise is reported loudly.
    raise warning 'slowmail_reader already existed with % -- something outside these migrations created it. Attributes are being reset; investigate why it was there.',
      array_to_string(v_bad, ', ');
  end if;
end;
$$;

alter role slowmail_reader
  nologin noinherit nobypassrls nocreaterole nocreatedb noreplication;

-- The ALTER above is the repair; this is the assertion. They are separate
-- because a repair that silently did nothing would look exactly like a repair
-- that worked.
do $$
begin
  if not exists (
    select 1 from pg_roles
    where rolname = 'slowmail_reader'
      and not rolsuper and not rolbypassrls and not rolcanlogin and not rolinherit
  ) then
    raise exception 'slowmail_reader still carries an attribute that would defeat RLS after normalisation';
  end if;
end;
$$;

do $$
begin
  execute format('grant slowmail_reader to %I', current_user);
end;
$$;

grant usage on schema public to slowmail_reader;

-- The reader has to be able to ask who is calling, and it cannot use auth.uid()
-- directly: schema auth is owned by supabase_admin and postgres holds usage on
-- it *without* grant option, so `grant usage on schema auth` succeeds with a
-- WARNING and grants nothing at all. A migration that appears to work and
-- silently does not is worse than one that fails, so the dependency is removed
-- rather than papered over.
--
-- SECURITY DEFINER owned by postgres, which does have that usage. This keeps
-- auth.uid() as the single source of identity instead of re-parsing the JWT
-- claims here, which would be a second copy free to drift from Supabase's.
create or replace function slowmail.current_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select auth.uid() $$;

grant usage on schema slowmail to slowmail_reader;
-- Same usage anon, authenticated and service_role already hold. Without it the
-- role cannot resolve anything in extensions, which among other things means the
-- pgTAP suite cannot make an assertion while acting as the read path.
grant usage on schema extensions to slowmail_reader;
grant execute on function slowmail.current_user_id() to slowmail_reader, authenticated;
grant select on public.letters to slowmail_reader;
grant insert (recipient_id, body) on public.letters to slowmail_reader;
grant update (body) on public.letters to slowmail_reader;
grant delete on public.letters to slowmail_reader;
grant execute on function public.is_accepted_correspondent(uuid) to slowmail_reader;

-- Same policy objects, one more role. Writing a second set of policies for the
-- reader would be two predicates that have to stay identical forever, which is
-- the drift the inverted freeze trigger already taught us to avoid.
-- Policy predicates are evaluated as the querying role, so they move to the
-- reachable identity source for the same reason the function bodies did. The
-- hold condition itself is untouched: deliver_at is still compared to now().
alter policy letters_select_sender on public.letters to authenticated, slowmail_reader
  using (sender_id = (select slowmail.current_user_id()));

alter policy letters_select_recipient on public.letters to authenticated, slowmail_reader
  using (
    recipient_id = (select slowmail.current_user_id())
    and deliver_at is not null
    and deliver_at <= now()
  );

alter policy letters_insert_own_draft on public.letters to authenticated, slowmail_reader
  with check (
    sender_id = (select slowmail.current_user_id())
    and recipient_id <> (select slowmail.current_user_id())
    and state = 'draft'
    and public.is_accepted_correspondent(recipient_id)
  );

alter policy letters_update_own_draft on public.letters to authenticated, slowmail_reader
  using (sender_id = (select slowmail.current_user_id()) and state = 'draft' and collected_at is null)
  with check (sender_id = (select slowmail.current_user_id()) and state = 'draft' and collected_at is null);

alter policy letters_delete_own_uncollected on public.letters to authenticated, slowmail_reader
  using (sender_id = (select slowmail.current_user_id()) and collected_at is null);

-- The read path. These functions contain no time predicate at all -- there is
-- deliberately no `deliver_at <= now()` anywhere below. The hold comes from the
-- policy underneath, so a careless edit here cannot open it, and the property is
-- asserted directly in the test suite.
--
-- plpgsql rather than sql: a SQL function is a candidate for inlining, and an
-- inlined body would be planned against the real table statistics, handing the
-- estimate oracle straight back. SECURITY DEFINER already blocks inlining; the
-- language choice means it stays blocked if that ever changes.
create or replace function public.mailbox()
returns setof public.letters
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select * from public.letters
  where recipient_id = slowmail.current_user_id()
  order by deliver_at desc;
end;
$$;

create or replace function public.outbox()
returns setof public.letters
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select * from public.letters
  where sender_id = slowmail.current_user_id()
  order by written_at desc nulls first;
end;
$$;

create or replace function public.correspondence(p_correspondent_id uuid)
returns setof public.letters
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select * from public.letters
  where (sender_id = slowmail.current_user_id() and recipient_id = p_correspondent_id)
     or (recipient_id = slowmail.current_user_id() and sender_id = p_correspondent_id)
  order by coalesce(deliver_at, written_at) desc;
end;
$$;

-- Writing a letter used to be an INSERT that returned its id so the client could
-- post it. RETURNING needs SELECT, and SELECT is what we just took away, so the
-- two steps become one call. This also removes the window in which a draft
-- existed with no collect_at.
create or replace function public.write_letter(p_recipient_id uuid, p_body text)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'SM005';
  end if;

  if p_recipient_id = auth.uid() then
    raise exception 'you cannot write to yourself' using errcode = 'SM007';
  end if;

  -- Re-stated rather than inherited: this function is SECURITY DEFINER and so
  -- runs past letters_insert_own_draft. The policy stays as the second line of
  -- defence for any path that is not this one.
  if not public.is_accepted_correspondent(p_recipient_id) then
    raise exception 'recipient is not an accepted correspondent' using errcode = 'SM007';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'cannot post an empty letter' using errcode = 'SM006';
  end if;

  insert into public.letters (sender_id, recipient_id, body, state)
  values (auth.uid(), p_recipient_id, p_body, 'draft')
  returning id into v_id;

  return public.post_letter(v_id);
end;
$$;

-- Ownership matters more than it looks. These functions must NOT be owned by
-- postgres: postgres carries BYPASSRLS, and a SECURITY DEFINER function owned by
-- it would sail straight past letters_select_recipient and hand back mail that
-- has not landed. slowmail_reader has no such attribute, so the policy still
-- applies inside the function body. CREATE on the schema is granted only for the
-- moment it takes to reassign, because a read role has no business making
-- objects.
do $$
declare
  v_fn text;
begin
  grant create on schema public to slowmail_reader;

  foreach v_fn in array array[
    'public.mailbox()',
    'public.outbox()',
    'public.correspondence(uuid)'
  ] loop
    execute format('alter function %s owner to slowmail_reader', v_fn);
    execute format('revoke all on function %s from public', v_fn);
    execute format('grant execute on function %s to authenticated', v_fn);
  end loop;

  revoke create on schema public from slowmail_reader;
end;
$$;

revoke all on function public.write_letter(uuid, text) from public;
grant execute on function public.write_letter(uuid, text) to authenticated;

-- The line that closes the leak. With no privilege at all on the table,
-- PostgREST stops exposing /letters entirely, so there is no resource left for
-- count=planned, count=estimated, embedded traversal or any future feature to
-- read an estimate from.
revoke all on public.letters from authenticated, anon;

comment on table public.letters is
  'Not reachable over PostgREST. Clients read through mailbox()/outbox()/correspondence() and write through write_letter()/revoke_letter()/mark_letter_read(). RLS still governs every one of those paths.';
