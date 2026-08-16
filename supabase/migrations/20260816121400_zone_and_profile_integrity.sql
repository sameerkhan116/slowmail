-- Two runtimes have to agree on a timezone, and on who lives in a territory.

-- Postgres accepts 1196 zone names; Deno's Intl accepts 598 of them. The entire
-- disagreement is the `posix/*` tree (measured against this Postgres build, and
-- `right/*` is included here because other builds ship it and it has the same
-- shape). `posix/America/New_York` therefore passed profile validation and then
-- made mailclock throw on every sweep, forever, for that user's mail. Validating
-- against the catalog alone is validating against the wrong runtime.
create or replace function slowmail.assert_valid_timezone()
returns trigger
language plpgsql
as $$
begin
  if new.timezone is null then
    return new;
  end if;

  if new.timezone like 'posix/%' or new.timezone like 'right/%' then
    raise exception 'timezone % is a Postgres-only alias and is rejected by the scheduling engine; use the plain IANA name', new.timezone
      using errcode = 'check_violation';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'invalid IANA timezone: %', new.timezone
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- mailclock checks isTerritory before it looks at the region, so the flag wins
-- any argument with the state code. That is correct for Guam, which really is a
-- flat 7 days, and wrong for Puerto Rico, which is a 5-day far-zone destination.
-- A PR user who sets is_territory because they read "territory" as describing
-- where they live silently adds two days to all their mail. The engine's
-- ordering is right; the data model has to stop offering the contradiction.
--
-- NOT VALID plus a best-effort validate: the rule binds every new and updated
-- row immediately, which is what protects mail, while a pre-existing bad row
-- surfaces as a loud warning rather than a database that will not boot.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_territory_excludes_states') then
    alter table public.profiles
      add constraint profiles_territory_excludes_states
      check (
        not (
          is_territory
          and country_code = 'US'
          and region in (
            'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA',
            'ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK',
            'OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC','PR'
          )
        )
      ) not valid;
  end if;
end;
$$;

-- A US profile with no region routes on great-circle distance alone, which puts
-- Anchorage in a 4-day band instead of the 5 it is always charged. Silent and
-- plausible, so it is refused rather than defaulted.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_us_requires_region') then
    alter table public.profiles
      add constraint profiles_us_requires_region
      check (country_code <> 'US' or region is not null) not valid;
  end if;
end;
$$;

do $$
declare
  v_bad integer;
begin
  begin
    alter table public.profiles validate constraint profiles_territory_excludes_states;
    alter table public.profiles validate constraint profiles_us_requires_region;
  exception when check_violation then
    select count(*) into v_bad from public.profiles
     where (country_code = 'US' and region is null)
        or (is_territory and country_code = 'US');
    raise warning 'profiles zone constraints left unvalidated: % existing row(s) violate them and will mis-route until corrected', v_bad;
  end;
end;
$$;

grant insert (region, is_territory) on public.profiles to authenticated;
grant update (region, is_territory) on public.profiles to authenticated;

-- A pending request should say who is asking, not where they sleep. The
-- profiles grant is table-wide, so the pending policy handed over home_lat and
-- home_lng to anyone who sent a request, accepted or not. Narrowing the policy
-- to accepted correspondents keeps requests answerable through a view that
-- exposes only the name.
drop policy if exists profiles_select_correspondent on public.profiles;

create policy profiles_select_correspondent on public.profiles
  for select to authenticated
  using (public.is_accepted_correspondent(id));

-- A view would not work here: security_invoker means it inherits the policy
-- just narrowed above and would return nothing for exactly the pending case it
-- exists to serve, while a plain view would hand back every column. So the card
-- is a function that selects the three columns itself and is the only thing
-- with permission to answer for a pending request.
create or replace function public.correspondent_card(p_user_id uuid)
returns table (id uuid, display_name text, home_city_label text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select p.id, p.display_name, p.home_city_label
  from public.profiles p
  where p.id = p_user_id
    and exists (
      select 1 from public.correspondents c
      where ((c.requester_id = auth.uid() and c.addressee_id = p.id)
          or (c.addressee_id = auth.uid() and c.requester_id = p.id))
        -- An edge alone is not permission. declined and blocked are edges too,
        -- and blocking someone has to stop them reading you or it is not
        -- blocking -- so the status is tested, not just the connection.
        and c.status in ('pending', 'accepted')
    );
end;
$$;

comment on function public.correspondent_card(uuid) is
  'Name and city for someone you have a correspondent edge with, pending or accepted. Deliberately cannot return coordinates.';

revoke all on function public.correspondent_card(uuid) from public;
grant execute on function public.correspondent_card(uuid) to authenticated;
