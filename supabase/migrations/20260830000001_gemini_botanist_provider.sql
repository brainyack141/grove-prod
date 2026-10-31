-- Gemini now answers every Ari request. Keep historical advice provenance as
-- recorded, but make any future insert that omits an explicit provider truthful.
alter table public.botanist_advice
  alter column provider set default 'google_gemini';

comment on column public.botanist_advice.provider is
  'Provider that produced the answer; Gemini is the production default.';
