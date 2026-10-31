// Backend tests run in Node; production imports the same source from the Edge
// Function directory so malformed PostgREST results cannot drift fail-open.
export * from "../supabase/functions/_shared/analysis-guest-job.mjs";
