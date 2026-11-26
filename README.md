# Savvy Signature Newsletter Studio

## Savvy Signature strategy defaults

The three starter editions follow `Savvy_Signature_Newsletter_Strategy_.pdf`: Australia publishes Tuesday afternoon in `Australia/Brisbane`; India publishes Wednesday in `Asia/Kolkata`; and New Zealand publishes Wednesday in `Pacific/Auckland`. The app uses editable recommended defaults of 2:00 PM for Brisbane and 9:00 AM for India and New Zealand because the brief gives only “Tuesday afternoon” for Australia and asks the team to confirm the other local release times. Update each edition's local time in **Newsletters → Edit settings** before launch.

The issue editor stores the wall-clock time alongside the edition's IANA timezone and displays both in the publishing calendar. Scheduling requires Monday approval, the market's configured weekday, and a 450–650 word draft. The editor shows each edition's story shape to help keep one practical takeaway in the draft. The dashboard tracks this workflow; automated LinkedIn publishing and timed delivery still require a publishing integration and background scheduler.

## Run locally

Use Node.js 20 or newer. Configure the values in `.env.example` in a private `.env` file, run `npm.cmd start`, then open `http://127.0.0.1:3000`. Opening `index.html` directly bypasses the server and database API.

## Connect the database

This app uses Supabase PostgreSQL through the server-side REST API. In Supabase, open the SQL editor and run `schema.sql`. It creates the `newsletter_studio_state` table used by the dashboard. In `.env`, set:

```env
SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
SUPABASE_SECRET_KEY=sb_secret_YOUR_SERVER_SIDE_KEY
```

Use the project secret key (`sb_secret_...`), not the publishable key (`sb_publishable_...`). Keep it only in the server's environment secrets. Never put it in `app.js`, HTML, or a public repository. The server also accepts the legacy `service_role` JWT through `SUPABASE_SERVICE_ROLE_KEY`. Restart the server after setting it. The dashboard shows **Database connected** when the API connects successfully.

On first connection, if the database row is empty, the dashboard migrates this browser's existing newsletter profiles, issues, activity, revisions, AI runs, and media library to the database. When a database record already exists, it loads that record and replaces the browser cache with it. Afterward, changes are saved to PostgreSQL and also cached locally for recovery if the database is temporarily unavailable. Check the status indicator and its hover text for save errors.

All dashboard records are stored in a single PostgreSQL `jsonb` snapshot row for this one-admin prototype. This retains editable newsletter profiles and schedules, issue titles and drafts, SEO fields, dates/statuses/destinations, revision history, AI runs, activity, and uploaded media previews. Uploaded PDF/Word drafts are extracted in-browser; the extracted draft becomes part of the issue record when saved. The original document file is not retained. For a larger production deployment, move image bytes to Supabase Storage and store their object paths in the database.

The snapshot table has Row Level Security enabled and grants access only to the server's `service_role`. The Node server holds that key. The current dashboard itself still needs a proper superadmin login before public production exposure; do not deploy this server publicly without adding authentication and HTTPS.

## AI refinement

The issue editor's **Refine with AI** button sends the draft and newsletter guidance from `server.mjs` to Cloudflare Workers AI. Configure `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, and optionally `CLOUDFLARE_MODEL` in `.env`. The server keeps provider credentials out of browser code. An AI suggestion is saved in the issue only when applied and the issue is saved; AI run metadata is recorded with the dashboard state.

## Publishing

The dashboard tracks LinkedIn and company website destinations, but automated publishing is not connected yet. A live publishing workflow still needs LinkedIn organization/API credentials, the company's CMS API, and a background scheduler. Store those credentials only as server-side environment secrets.
