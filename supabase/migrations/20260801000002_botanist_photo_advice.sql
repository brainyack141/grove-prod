begin;

-- Photo identity answers have their own deterministic route and verification
-- marker. Keep those values explicit so photo-backed advice can be retained
-- without pretending it travelled through a text-only route.
alter table public.botanist_advice
  drop constraint if exists botanist_advice_route_tier_check;

alter table public.botanist_advice
  add constraint botanist_advice_route_tier_check
  check (route_tier in ('legacy', 'routine', 'standard', 'complex', 'safety', 'photo_identity'));

alter table public.botanist_advice
  drop constraint if exists botanist_advice_verification_status_check;

alter table public.botanist_advice
  add constraint botanist_advice_verification_status_check
  check (verification_status in (
    'not_required',
    'policy_override',
    'approve',
    'revise',
    'withhold',
    'withheld',
    'photo_scan'
  ));

commit;
