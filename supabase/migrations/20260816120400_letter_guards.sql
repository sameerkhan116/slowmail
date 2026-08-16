-- Immutability and state-machine guards for letters.
--
-- These run for every role, including postgres and service_role. Column
-- privileges already stop a client from touching the schedule; this layer makes
-- the product rule true no matter which connection is holding the wheel.
--
-- SQLSTATEs are stable so tests and clients can branch on them:
--   SM001  the letter is collected and therefore frozen
--   SM002  illegal state transition
--   SM003  the body is sealed
--   SM004  a collected letter cannot be deleted

create or replace function slowmail.guard_letter_write()
returns trigger
language plpgsql
as $$
declare
  v_frozen boolean;
begin
  if tg_op = 'DELETE' then
    if old.collected_at is not null then
      raise exception 'letter % was collected on % and can no longer be deleted', old.id, old.collected_at
        using errcode = 'SM004';
    end if;
    return old;
  end if;

  -- Identity never moves, at any stage.
  if new.id is distinct from old.id
     or new.sender_id is distinct from old.sender_id
     or new.recipient_id is distinct from old.recipient_id then
    raise exception 'letter identity is immutable'
      using errcode = 'SM001';
  end if;

  -- The body is sealed the moment the letter leaves the writer's hands.
  -- Before that only a draft is editable; pulling a posted letter back means
  -- revoking it, not rewriting it.
  if new.body is distinct from old.body and old.state <> 'draft' then
    raise exception 'letter % is posted; its body can no longer be changed', old.id
      using errcode = 'SM003';
  end if;

  v_frozen := old.collected_at is not null;

  if v_frozen then
    if new.body is distinct from old.body
       or new.written_at is distinct from old.written_at
       or new.collect_at is distinct from old.collect_at
       or new.collected_at is distinct from old.collected_at
       or new.postmark_date is distinct from old.postmark_date
       or new.transit_days is distinct from old.transit_days
       or new.deliver_at is distinct from old.deliver_at
       or new.revoked_at is distinct from old.revoked_at
       or new.sender_tz is distinct from old.sender_tz
       or new.sender_lat is distinct from old.sender_lat
       or new.sender_lng is distinct from old.sender_lng
       or new.sender_country_code is distinct from old.sender_country_code
       or new.sender_is_territory is distinct from old.sender_is_territory
       or new.recipient_tz is distinct from old.recipient_tz
       or new.recipient_lat is distinct from old.recipient_lat
       or new.recipient_lng is distinct from old.recipient_lng
       or new.recipient_country_code is distinct from old.recipient_country_code
       or new.schedule_source is distinct from old.schedule_source then
      raise exception 'letter % was collected on %; its contents and schedule are frozen', old.id, old.collected_at
        using errcode = 'SM001';
    end if;
  end if;

  -- Delivery and read receipts are write-once, forward-only.
  if old.delivered_at is not null and new.delivered_at is distinct from old.delivered_at then
    raise exception 'delivered_at is write-once' using errcode = 'SM001';
  end if;
  if old.read_at is not null and new.read_at is distinct from old.read_at then
    raise exception 'read_at is write-once' using errcode = 'SM001';
  end if;

  if old.state is distinct from new.state then
    if not (
      (old.state = 'draft' and new.state in ('awaiting_collection', 'revoked'))
      or (old.state = 'awaiting_collection' and new.state in ('in_transit', 'revoked'))
      or (old.state = 'in_transit' and new.state = 'delivered')
    ) then
      raise exception 'letter % cannot move from % to %', old.id, old.state, new.state
        using errcode = 'SM002';
    end if;
  end if;

  return new;
end;
$$;

create trigger letters_guard_write
  before update or delete on public.letters
  for each row execute function slowmail.guard_letter_write();
