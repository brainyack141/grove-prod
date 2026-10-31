begin;

-- Contract v6 records which provider actually answered, supports replay-safe
-- request ids, and retains only a bounded derived visual evidence block. Raw
-- questions, conversations, plant context and image bytes remain absent.
alter table public.botanist_advice
  add column if not exists provider text not null default 'deepseek',
  add column if not exists verifier_model text,
  add column if not exists request_id uuid,
  add column if not exists attachment_count integer not null default 0,
  add column if not exists visual_evidence text;

alter table public.botanist_advice
  add constraint botanist_advice_attachment_count_check
  check (attachment_count between 0 and 2),
  add constraint botanist_advice_visual_evidence_check
  check (visual_evidence is null or char_length(visual_evidence) <= 4000);

create unique index if not exists botanist_advice_account_request_idx
  on public.botanist_advice (account_id, request_id)
  where request_id is not null;

create table public.botanist_requests (
    account_id text not null,
    request_id uuid not null,
    state text not null check (state in ('processing', 'completed', 'limited')),
    advice_id uuid references public.botanist_advice(id) on delete set null,
    claimed_at timestamptz not null default now(),
    completed_at timestamptz,
    primary key (account_id, request_id)
);

create index botanist_requests_claimed_idx
  on public.botanist_requests (claimed_at)
  where state = 'processing';

alter table public.botanist_requests enable row level security;
revoke all on public.botanist_requests from public;
revoke all on public.botanist_requests from anon;
revoke all on public.botanist_requests from authenticated;
grant select, insert, update, delete on public.botanist_requests to service_role;

-- Atomically claims a stable user-message request id and counts provider spend
-- only once. A completed response can be replayed, a live duplicate cannot run
-- a second provider call, and an abandoned worker can be reclaimed after three
-- minutes. The claim stores identifiers and state only.
create function public.botanist_claim_request(
  p_account_id text,
  p_request_id uuid,
  p_daily_limit integer
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_count integer;
  existing_state text;
  existing_claimed_at timestamptz;
  existing_advice uuid;
  used integer;
begin
  insert into public.botanist_requests (account_id, request_id, state)
  values (p_account_id, p_request_id, 'processing')
  on conflict do nothing;
  get diagnostics inserted_count = row_count;

  if inserted_count = 1 then
    used := public.botanist_record_ask(p_account_id, p_daily_limit);
    if used < 0 then
      update public.botanist_requests
      set state = 'limited'
      where account_id = p_account_id and request_id = p_request_id;
      return 'limited';
    end if;
    return 'claimed';
  end if;

  select state, claimed_at, advice_id
  into existing_state, existing_claimed_at, existing_advice
  from public.botanist_requests
  where account_id = p_account_id and request_id = p_request_id
  for update;

  if existing_state = 'completed' then return 'completed'; end if;
  if existing_state = 'limited' then
    if (existing_claimed_at at time zone 'utc')::date
       < (now() at time zone 'utc')::date then
      used := public.botanist_record_ask(p_account_id, p_daily_limit);
      if used < 0 then
        update public.botanist_requests
        set claimed_at = now()
        where account_id = p_account_id and request_id = p_request_id;
        return 'limited';
      end if;
      update public.botanist_requests
      set state = 'processing', claimed_at = now()
      where account_id = p_account_id and request_id = p_request_id;
      return 'claimed';
    end if;
    return 'limited';
  end if;

  if existing_advice is null then
    select id into existing_advice
    from public.botanist_advice
    where account_id = p_account_id and request_id = p_request_id;
    if existing_advice is not null then
      update public.botanist_requests
      set state = 'completed', advice_id = existing_advice, completed_at = now()
      where account_id = p_account_id and request_id = p_request_id;
      return 'completed';
    end if;
  end if;

  if existing_claimed_at < now() - interval '3 minutes' then
    update public.botanist_requests
    set claimed_at = now()
    where account_id = p_account_id and request_id = p_request_id;
    return 'claimed';
  end if;
  return 'processing';
end;
$$;

create function public.botanist_complete_request(
  p_account_id text,
  p_request_id uuid,
  p_advice_id uuid
)
returns boolean
language sql
security definer
set search_path = public
as $$
  update public.botanist_requests
  set state = 'completed', advice_id = p_advice_id, completed_at = now()
  where account_id = p_account_id
    and request_id = p_request_id
    and state = 'processing'
  returning true;
$$;

create function public.botanist_release_request(p_account_id text, p_request_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  delete from public.botanist_requests
  where account_id = p_account_id
    and request_id = p_request_id
    and state = 'processing'
    and advice_id is null
  returning true;
$$;

revoke all on function public.botanist_claim_request(text, uuid, integer) from public;
revoke all on function public.botanist_claim_request(text, uuid, integer) from anon;
revoke all on function public.botanist_claim_request(text, uuid, integer) from authenticated;
grant execute on function public.botanist_claim_request(text, uuid, integer) to service_role;
revoke all on function public.botanist_complete_request(text, uuid, uuid) from public;
revoke all on function public.botanist_complete_request(text, uuid, uuid) from anon;
revoke all on function public.botanist_complete_request(text, uuid, uuid) from authenticated;
grant execute on function public.botanist_complete_request(text, uuid, uuid) to service_role;
revoke all on function public.botanist_release_request(text, uuid) from public;
revoke all on function public.botanist_release_request(text, uuid) from anon;
revoke all on function public.botanist_release_request(text, uuid) from authenticated;
grant execute on function public.botanist_release_request(text, uuid) to service_role;

commit;
