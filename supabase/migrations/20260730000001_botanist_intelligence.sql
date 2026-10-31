begin;

-- Durable, privacy-minimised memory for Botanist v2.
--
-- The raw question, conversation and plant context are deliberately not stored.
-- A later ask only needs to know what Grove advised, why, and what happened
-- afterwards. `account_id` is text and there is no foreign key because guest and
-- demo identities can use the botanist without existing in app.accounts.
create table public.botanist_advice (
    id uuid primary key default gen_random_uuid(),
    account_id text not null,
    plant_id uuid,
    thread_id uuid,
    reply text not null check (char_length(reply) between 1 and 1500),
    disposition text not null check (disposition in ('answer', 'clarify', 'escalate')),
    confidence text not null check (confidence in ('low', 'medium', 'high')),
    evidence jsonb not null default '[]'::jsonb,
    missing_information jsonb not null default '[]'::jsonb,
    source_ids jsonb not null default '[]'::jsonb,
    safety_topics jsonb not null default '[]'::jsonb,
    route_tier text not null check (route_tier in ('legacy', 'routine', 'standard', 'complex', 'safety')),
    route_reason text not null,
    verification_status text not null
      check (verification_status in ('not_required', 'policy_override', 'approve', 'revise', 'withhold', 'withheld')),
    verification_issues jsonb not null default '[]'::jsonb,
    follow_up_at timestamptz,
    helpful boolean,
    plant_outcome text check (plant_outcome in ('improved', 'same', 'worse')),
    outcome_recorded_at timestamptz,
    knowledge_version text not null,
    model text not null,
    provider_usage jsonb,
    latency_ms integer not null check (latency_ms >= 0),
    created_at timestamptz not null default now()
);

create index botanist_advice_account_created_idx
  on public.botanist_advice (account_id, created_at desc);

create index botanist_advice_plant_created_idx
  on public.botanist_advice (account_id, plant_id, created_at desc)
  where plant_id is not null;

create index botanist_advice_follow_up_idx
  on public.botanist_advice (account_id, follow_up_at)
  where follow_up_at is not null and plant_outcome is null;

alter table public.botanist_advice enable row level security;

-- The Edge Function uses the service-role client. No app role can enumerate,
-- insert or alter another person's model history directly.
revoke all on public.botanist_advice from public;
revoke all on public.botanist_advice from anon;
revoke all on public.botanist_advice from authenticated;

commit;
