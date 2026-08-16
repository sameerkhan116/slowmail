-- Posting twice because the first reply went missing.
--
-- `write_letter` inserts the letter and calls `post_letter` before its reply is
-- serialised, so a connection that drops after the commit leaves the sender
-- looking at a failure for mail that was genuinely sent. The obvious thing to
-- do next is tap Post again, and that second letter is a real one: once it is
-- collected neither party can recall it, and the recipient opens the same words
-- twice, days apart, with no way to tell which was meant.
--
-- Retrying is the correct behaviour for the client -- it cannot distinguish
-- "the request never arrived" from "the reply never came back", and refusing to
-- retry would lose real letters. So the retry has to be made safe instead, and
-- that requires the client to say which letter it means. A key chosen by the
-- sender before the first attempt is the same on every retry of that attempt,
-- and different for a letter they genuinely wrote twice.

alter table public.letters
  add column if not exists client_key uuid;

comment on column public.letters.client_key is
  'Chosen by the sender before the first attempt to post, so a retry after a '
  'lost reply is recognised as the same letter rather than a second one. Null '
  'on letters written before this existed.';

-- Partial, because every letter posted before this migration has no key and
-- those nulls must not collide with each other.
create unique index if not exists letters_sender_client_key
  on public.letters (sender_id, client_key)
  where client_key is not null;

-- The old two-argument form is dropped rather than kept alongside. Leaving it
-- would leave the unsafe path reachable, and a client that had not been updated
-- would keep posting duplicates while looking like it worked.
drop function if exists public.write_letter(uuid, text);

create or replace function public.write_letter(
  p_recipient_id uuid,
  p_body text,
  p_client_key uuid
)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_existing public.letters;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'SM005';
  end if;

  -- Required, not optional. An optional key is one the client can forget to
  -- send, and the failure is silent: everything works until the day a reply is
  -- lost, which is the only day it mattered.
  if p_client_key is null then
    raise exception 'a client key is required to post' using errcode = 'SM006';
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

  -- Scoped to the caller, so one sender's key cannot be used to discover
  -- whether another sender has posted anything.
  select * into v_existing
  from public.letters
  where sender_id = auth.uid() and client_key = p_client_key;

  if found then
    return v_existing;
  end if;

  begin
    insert into public.letters (sender_id, recipient_id, body, state, client_key)
    values (auth.uid(), p_recipient_id, p_body, 'draft', p_client_key)
    returning id into v_id;
  exception when unique_violation then
    -- Two attempts genuinely overlapped. The loser blocked on the index until
    -- the winner committed, so by now the winning letter is posted and visible;
    -- return it rather than the caller's own half-made one.
    select * into v_existing
    from public.letters
    where sender_id = auth.uid() and client_key = p_client_key;
    return v_existing;
  end;

  return public.post_letter(v_id);
end;
$$;

revoke all on function public.write_letter(uuid, text, uuid) from public, anon;
grant execute on function public.write_letter(uuid, text, uuid) to authenticated;

comment on function public.write_letter(uuid, text, uuid) is
  'Write and post a letter in one statement. Idempotent per (sender, '
  'client_key): retrying after a lost reply returns the letter already posted '
  'rather than posting a second one.';

-- The body of a letter is sealed once posted, and `client_key` is not in the
-- set of columns that may move after collection, so it is frozen with the rest
-- of the envelope by the existing guard. Asserted here so that a future rewrite
-- of that guard which forgets this column fails at migration time.
do $$
begin
  if exists (
    select 1 from pg_attribute
    where attrelid = 'public.letters'::regclass
      and attname = 'client_key'
      and attisdropped
  ) then
    raise exception 'client_key must exist on public.letters';
  end if;
end;
$$;
