-- Scheduling: two jobs, five minutes apart from nothing.
--
-- Both dispatchers read their credentials from Supabase Vault at call time.
-- Nothing secret is written by this migration; see supabase/README.md for the
-- one-time bootstrap. An unconfigured project logs a notice and does nothing
-- rather than failing the job.

create or replace function slowmail.setting(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_value text;
begin
  if to_regclass('vault.decrypted_secrets') is null then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
    into v_value using p_name;
  return v_value;
end;
$$;

revoke all on function slowmail.setting(text) from public;

create or replace function slowmail.invoke_edge_function(p_function_name text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base_url text := slowmail.setting('slowmail_functions_url');
  v_key text := slowmail.setting('slowmail_service_role_key');
begin
  if v_base_url is null or v_key is null then
    raise notice 'slowmail: edge function % not invoked, vault secrets are not configured', p_function_name;
    return null;
  end if;

  return net.http_post(
    url := rtrim(v_base_url, '/') || '/' || p_function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := p_body,
    timeout_milliseconds := 20000
  );
end;
$$;

revoke all on function slowmail.invoke_edge_function(text, jsonb) from public;

-- Collection needs the timing engine, which is TypeScript, so the job pokes an
-- edge function rather than doing the arithmetic in SQL.
create or replace function slowmail.dispatch_collection()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.letters
    where state = 'awaiting_collection'
      and collect_at <= now()
      and (collection_claimed_at is null or collection_claimed_at < now() - interval '15 minutes')
  ) then
    return;
  end if;

  perform slowmail.invoke_edge_function('postal-collection');
end;
$$;

revoke all on function slowmail.dispatch_collection() from public;

create or replace function slowmail.dispatch_delivery()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result record;
begin
  select * into v_result from slowmail.run_delivery();

  if v_result.pushes_queued > 0 then
    perform slowmail.invoke_edge_function('deliver-push');
  end if;
end;
$$;

revoke all on function slowmail.dispatch_delivery() from public;

do $$
begin
  if to_regproc('cron.schedule(text,text,text)') is null then
    raise notice 'slowmail: pg_cron is unavailable, postal jobs were not scheduled';
    return;
  end if;

  -- cron.schedule upserts on job name, so a replayed migration re-points the
  -- existing job instead of stacking a second one.
  perform cron.schedule('slowmail-collection', '*/5 * * * *', $job$select slowmail.dispatch_collection();$job$);
  perform cron.schedule('slowmail-delivery', '*/5 * * * *', $job$select slowmail.dispatch_delivery();$job$);
end;
$$;
