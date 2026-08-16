-- The outbox is posted mail, not everything the table happens to hold.
--
-- `outbox()` returned every row with the caller as sender, `letter_state`
-- includes 'draft', and the client renders anything that is not in transit or
-- delivered as awaiting collection. A draft would therefore be shown as "will
-- be collected at 5pm" -- a promise about mail that will never move, because a
-- draft has no `collect_at` and no sweep will ever pick it up.
--
-- Today that is unreachable rather than untrue: `write_letter` creates and posts
-- in one statement, `authenticated` holds no privilege on `public.letters` at
-- all, and `slowmail_reader` is NOLOGIN NOINHERIT with only `postgres` as a
-- member, so no client can leave a draft lying in the table.
--
-- "Unreachable today" is the kind of guarantee that quietly stops being true.
-- Filtering here makes the current behaviour explicit and changes how a future
-- save-draft path fails: instead of drafts silently rendering as posted mail in
-- a shipped client, they are absent from the outbox, which whoever builds that
-- path notices on their first run. A wrong answer in production becomes a
-- missing answer in development.
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
    and state <> 'draft'
  order by written_at desc nulls first;
end;
$$;

-- Ownership is what makes the hold hold: slowmail_reader has neither BYPASSRLS
-- nor ownership of letters, so the recipient policy still binds inside this
-- definer body. `create or replace` preserves the owner, but stating it here
-- means a future rewrite that drops and recreates the function cannot lose it
-- silently.
alter function public.outbox() owner to slowmail_reader;

revoke all on function public.outbox() from public, anon;
grant execute on function public.outbox() to authenticated;

comment on function public.outbox() is
  'Mail the caller has posted, at every stage including in transit. Excludes '
  'drafts: they are not in the postal system and have no schedule to show.';
