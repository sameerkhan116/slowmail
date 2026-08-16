-- Correspondents: a mutual link that must exist before mail can be addressed.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'correspondent_status') then
    create type public.correspondent_status as enum ('pending', 'accepted', 'declined', 'blocked');
  end if;
end;
$$;

create table if not exists public.correspondents (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status public.correspondent_status not null default 'pending',
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint correspondents_not_self check (requester_id <> addressee_id),
  constraint correspondents_responded_at_matches_status
    check ((status = 'pending') = (responded_at is null))
);

-- One link per unordered pair, so A->B and B->A cannot both exist.
create unique index if not exists correspondents_pair_key
  on public.correspondents (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

create index if not exists correspondents_addressee_pending
  on public.correspondents (addressee_id) where status = 'pending';

comment on table public.correspondents is 'Mutual connection between two users. A letter may only be addressed to an accepted correspondent.';

alter table public.correspondents enable row level security;
alter table public.correspondents force row level security;

revoke all on public.correspondents from anon, authenticated;
grant select on public.correspondents to authenticated;
grant insert (addressee_id) on public.correspondents to authenticated;
grant update (status) on public.correspondents to authenticated;
grant delete on public.correspondents to authenticated;

alter table public.correspondents alter column requester_id set default auth.uid();

create policy correspondents_select_involved on public.correspondents
  for select to authenticated
  using (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()));

create policy correspondents_insert_as_requester on public.correspondents
  for insert to authenticated
  with check (requester_id = (select auth.uid()));

-- Only the addressee answers a request; either side may later block.
create policy correspondents_update_response on public.correspondents
  for update to authenticated
  using (
    (addressee_id = (select auth.uid()) and status = 'pending')
    or ((requester_id = (select auth.uid()) or addressee_id = (select auth.uid())) and status = 'accepted')
  )
  with check (
    (addressee_id = (select auth.uid()) and status in ('accepted', 'declined', 'blocked'))
    or ((requester_id = (select auth.uid()) or addressee_id = (select auth.uid())) and status = 'blocked')
  );

-- Withdrawing your own unanswered request.
create policy correspondents_delete_own_pending on public.correspondents
  for delete to authenticated
  using (requester_id = (select auth.uid()) and status = 'pending');

create or replace function slowmail.stamp_correspondent_response()
returns trigger
language plpgsql
as $$
begin
  if new.status <> 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    new.responded_at := now();
  end if;
  return new;
end;
$$;

create trigger correspondents_stamp_response
  before insert or update on public.correspondents
  for each row execute function slowmail.stamp_correspondent_response();

-- Asked as "is this person my correspondent", never "are these two people
-- connected", so it cannot be used to map links between strangers.
create or replace function public.is_accepted_correspondent(other_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.correspondents c
    where c.status = 'accepted'
      and (
        (c.requester_id = auth.uid() and c.addressee_id = other_user)
        or (c.addressee_id = auth.uid() and c.requester_id = other_user)
      )
  );
$$;

revoke all on function public.is_accepted_correspondent(uuid) from public;
grant execute on function public.is_accepted_correspondent(uuid) to authenticated, service_role;

-- Deferred from the profiles migration: visibility of a counterpart's profile.
-- Pending is included so an incoming request shows a name, not a bare uuid.
create policy profiles_select_correspondent on public.profiles
  for select to authenticated
  using (
    exists (
      select 1
      from public.correspondents c
      where c.status in ('pending', 'accepted')
        and (
          (c.requester_id = (select auth.uid()) and c.addressee_id = public.profiles.id)
          or (c.addressee_id = (select auth.uid()) and c.requester_id = public.profiles.id)
        )
    )
  );
