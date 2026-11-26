-- Signal & Story Newsletter Studio
-- PostgreSQL 15+ / Supabase-compatible starter schema.
-- Apply once to a new database. The UI prototype currently uses localStorage;
-- connect a server-side API and enable RLS policies before production use.

create extension if not exists pgcrypto;

-- Dashboard storage API: one durable JSONB snapshot for every UI record
-- (newsletter profiles, issues, revisions, AI runs, activity, and media).
-- This table is read/written only by the server using its private service key.
create table if not exists public.newsletter_studio_state (
  id text primary key check (id = 'primary'),
  state jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.newsletter_studio_state enable row level security;
revoke all on table public.newsletter_studio_state from public, anon, authenticated;
grant all on table public.newsletter_studio_state to service_role;

create type public.issue_status as enum ('draft', 'in_review', 'approved', 'scheduled', 'publishing', 'published', 'failed', 'archived');
create type public.destination_kind as enum ('linkedin', 'website');
create type public.destination_status as enum ('pending', 'scheduled', 'publishing', 'published', 'failed', 'skipped');
create type public.revision_source as enum ('manual', 'ai_refinement', 'import');

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Membership uses Supabase Auth IDs when hosted on Supabase.
create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'superadmin' check (role = 'superadmin'),
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
-- This workspace supports one principal account only.
create unique index workspace_single_superadmin_idx on public.workspace_members(workspace_id);

create table public.newsletters (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  -- slug is a stable internal key; display_name stays editable.
  slug text not null,
  display_name text not null,
  region text not null default '',
  audience text not null default '',
  language text not null default 'English',
  timezone text not null default 'UTC',
  editorial_guidance text not null default '',
  seo_guidance text not null default '',
  image_guidance text not null default '',
  min_words integer check (min_words is null or min_words >= 0),
  max_words integer check (max_words is null or max_words >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, slug),
  check (max_words is null or min_words is null or max_words >= min_words)
);

create table public.publishing_schedules (
  id uuid primary key default gen_random_uuid(),
  newsletter_id uuid not null references public.newsletters(id) on delete cascade,
  label text not null default 'Primary schedule',
  -- RRULE-compatible recurrence string; leave null for a one-off schedule.
  recurrence_rule text,
  timezone text not null,
  local_time time,
  weekdays smallint[] not null default '{}',
  next_run_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (weekdays <@ array[0,1,2,3,4,5,6])
);

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  storage_bucket text not null default 'newsletter-media',
  storage_path text not null,
  original_filename text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size >= 0),
  width integer,
  height integer,
  alt_text text not null default '',
  attribution text not null default '',
  uploaded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

create table public.issues (
  id uuid primary key default gen_random_uuid(),
  newsletter_id uuid not null references public.newsletters(id) on delete restrict,
  content_title text not null,
  slug text,
  body_markdown text not null default '',
  body_html text,
  seo_meta_title text not null default '',
  seo_meta_description text not null default '',
  canonical_url text,
  featured_image_id uuid references public.media_assets(id) on delete set null,
  status public.issue_status not null default 'draft',
  scheduled_at timestamptz,
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  check (seo_meta_title = '' or char_length(seo_meta_title) <= 70),
  check (seo_meta_description = '' or char_length(seo_meta_description) <= 170)
);
create index issues_newsletter_status_idx on public.issues(newsletter_id, status);
create index issues_scheduled_at_idx on public.issues(scheduled_at) where scheduled_at is not null;
create index issues_updated_at_idx on public.issues(updated_at desc);

-- Full snapshots allow the editor to compare, restore, and audit every version.
create table public.issue_revisions (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  revision_number integer not null check (revision_number > 0),
  source public.revision_source not null default 'manual',
  content_title text not null,
  body_markdown text not null default '',
  seo_meta_title text not null default '',
  seo_meta_description text not null default '',
  featured_image_id uuid references public.media_assets(id) on delete set null,
  editor_note text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (issue_id, revision_number)
);

-- Store exact prompt/config and model details for AI-generated edits.
create table public.ai_refinement_runs (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  input_revision_id uuid references public.issue_revisions(id) on delete set null,
  output_revision_id uuid references public.issue_revisions(id) on delete set null,
  provider text not null,
  model text not null,
  prompt_version text not null,
  rules_snapshot jsonb not null default '{}'::jsonb,
  request_metadata jsonb not null default '{}'::jsonb,
  result_metadata jsonb not null default '{}'::jsonb,
  status text not null default 'completed' check (status in ('queued','completed','failed')),
  error_message text,
  requested_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- One issue may publish independently to LinkedIn and the company website.
create table public.issue_destinations (
  id uuid primary key default gen_random_uuid(),
  issue_id uuid not null references public.issues(id) on delete cascade,
  destination public.destination_kind not null,
  status public.destination_status not null default 'pending',
  scheduled_at timestamptz,
  published_at timestamptz,
  external_id text,
  published_url text,
  -- Site CMS target, LinkedIn organization/profile ID, and connector settings.
  config jsonb not null default '{}'::jsonb,
  last_error text,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (issue_id, destination)
);
create index issue_destinations_queue_idx on public.issue_destinations(status, scheduled_at);

create table public.publishing_attempts (
  id uuid primary key default gen_random_uuid(),
  issue_destination_id uuid not null references public.issue_destinations(id) on delete cascade,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null,
  response_code integer,
  response_summary text not null default '',
  external_id text,
  published_url text,
  initiated_by uuid references auth.users(id) on delete set null
);
create index publishing_attempts_destination_idx on public.publishing_attempts(issue_destination_id, attempted_at desc);

create table public.activity_log (
  id bigint generated always as identity primary key,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  summary text not null,
  changes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index activity_log_workspace_time_idx on public.activity_log(workspace_id, created_at desc);

create function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
create trigger workspaces_set_updated_at before update on public.workspaces for each row execute function public.set_updated_at();
create trigger newsletters_set_updated_at before update on public.newsletters for each row execute function public.set_updated_at();
create trigger schedules_set_updated_at before update on public.publishing_schedules for each row execute function public.set_updated_at();
create trigger issues_set_updated_at before update on public.issues for each row execute function public.set_updated_at();
create trigger issue_destinations_set_updated_at before update on public.issue_destinations for each row execute function public.set_updated_at();

-- Optional starter workspace + editable newsletter profiles. Run after schema creation.
-- This creates the workspace and four newsletters once. Schedule times are editable later.
with w as (
  insert into public.workspaces (name) values ('SS Workspace') returning id
)
insert into public.newsletters
  (workspace_id, slug, display_name, region, audience, language, timezone, editorial_guidance, seo_guidance, image_guidance)
select w.id, seed.slug, seed.display_name, seed.region, seed.audience, seed.language, seed.timezone, seed.editorial_guidance, seed.seo_guidance, seed.image_guidance
from w cross join (values
 ('tech','Are you Tech Savvy?','Global','Technology readers with mixed technical confidence','English · international spelling','Asia/Kolkata','Use clear, curious, practical language. Explain jargon on first use. Prefer globally understood examples; avoid assuming one country’s products, infrastructure, or regulations. Keep claims sourced and avoid hype.','Use descriptive, accurate titles and plain-language descriptions. Avoid keyword stuffing.','Use relevant, licensed images with concise descriptive alt text.'),
 ('au','SS Australia','Australia','Australian business audience','English · Australian spelling','Australia/Sydney','Use Australian spelling and locally familiar terminology. Ground examples in Australian industries, institutions, seasons, dates, and units. Avoid US-centric assumptions and check local claims and references.','Use Australian terminology and search phrasing when relevant; avoid US-only terms.','Use locally relevant, licensed images with descriptive alt text.'),
 ('nz','SS New Zealand','New Zealand','New Zealand business audience','English · New Zealand spelling','Pacific/Auckland','Use New Zealand spelling and locally relevant terminology. Avoid treating New Zealand as an extension of Australia or defaulting to US references. Use Māori words and cultural references thoughtfully, never decoratively.','Use New Zealand terminology and search phrasing when relevant.','Use locally relevant, licensed images with descriptive alt text.'),
 ('india','SS India','India','Broad Indian business audience','English · Indian English','Asia/Kolkata','Use clear Indian English and locally familiar examples, dates, currencies, and units. Avoid assuming one language, region, religion, income level, or urban experience represents all of India. Check regulatory and market claims.','Use relevant Indian search phrasing and explain region-specific terms for broad audiences.','Use locally relevant, licensed images; add descriptive alt text and context.')
) as seed(slug,display_name,region,audience,language,timezone,editorial_guidance,seo_guidance,image_guidance);

-- Production note: enable RLS and add policies that scope every row to the
-- caller's workspace_members membership. Keep publishing/AI secrets server-side.
