// Backend tests run in Node; production imports the same source from the Edge
// Function directory so the security classification cannot drift between them.
export * from "../supabase/functions/_shared/analysis-identity.mjs";
