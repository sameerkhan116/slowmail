-- Row level security for letters.
--
-- The rule the product is built on: a recipient must not be able to learn a
-- letter exists before it lands. Not the body, not the sender, not a count.
-- That is expressed here as a policy predicate, so it holds for SELECT,
-- for count(*), and for the RETURNING clause of any statement, whatever the
-- client asks for.

alter table public.letters enable row level security;
-- FORCE so the table owner is not quietly exempt.
alter table public.letters force row level security;

revoke all on public.letters from anon, authenticated;

grant select on public.letters to authenticated;
-- The only columns a client may ever write. Everything schedule-shaped is
-- absent, so `insert ... (deliver_at) values (now())` is rejected by the
-- privilege system before a policy is even consulted.
grant insert (recipient_id, body) on public.letters to authenticated;
grant update (body) on public.letters to authenticated;
grant delete on public.letters to authenticated;

-- A sender sees their own mail at every stage, including in transit.
create policy letters_select_sender on public.letters
  for select to authenticated
  using (sender_id = (select auth.uid()));

-- A recipient sees nothing until the carrier has been. deliver_at is null for
-- drafts, awaiting and revoked letters, so those are invisible by construction;
-- in-transit letters are invisible until their delivery instant passes.
create policy letters_select_recipient on public.letters
  for select to authenticated
  using (
    recipient_id = (select auth.uid())
    and deliver_at is not null
    and deliver_at <= now()
  );

-- You cannot mail a stranger.
create policy letters_insert_own_draft on public.letters
  for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and recipient_id <> (select auth.uid())
    and state = 'draft'
    and public.is_accepted_correspondent(recipient_id)
  );

-- Only an uncollected draft is editable, and only by its writer.
create policy letters_update_own_draft on public.letters
  for update to authenticated
  using (sender_id = (select auth.uid()) and state = 'draft' and collected_at is null)
  with check (sender_id = (select auth.uid()) and state = 'draft' and collected_at is null);

create policy letters_delete_own_uncollected on public.letters
  for delete to authenticated
  using (sender_id = (select auth.uid()) and collected_at is null);
