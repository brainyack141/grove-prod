# Grove analysis + sync API on Node 24 LTS. The only runtime dependency is the Postgres
# driver used to reach Supabase; everything else is Node core.
# syntax=docker/dockerfile:1
FROM node:24-alpine

WORKDIR /app

# Manifests first so dependency installation is cached across source-only changes.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production \
    PORT=8080 \
    HOST=0.0.0.0

EXPOSE 8080

# Required/optional runtime config comes from the host's secret store, never the image:
#   GEMINI_API_KEY    (required)  — your Google Gemini key
#   SUPABASE_DB_URL   (recommended) — Supabase transaction-pooler connection string
#   PUBLIC_BASE_URL   (recommended) — e.g. https://<your-app>.fly.dev
#   GROVE_APP_KEY     (optional)  — shared secret the app must send as X-Grove-App-Key
CMD ["node", "server.mjs"]
