-- mf-sync mirror schema (idempotent). db9/TiKV: no pg_trgm, use convert_from for text.
create schema if not exists memoryfield;

-- one row per page; `field` = memoryfield dir name, so several fields can share one database
create table if not exists memoryfield.pages (
  field         text not null,
  slug          text not null,
  title         text,
  summary       text,
  status        text,
  status_reason text,
  uuid          text,
  page_created  timestamptz,
  page_updated  timestamptz,
  bytes         integer,
  sha256        text,
  body          text,          -- byte-exact file content, frontmatter included
  updated_by    text,          -- host that pushed this version
  synced_at     timestamptz default now(),
  primary key (field, slug)
);
create index if not exists pages_updated_idx on memoryfield.pages (field, page_updated desc);
create index if not exists pages_status_idx  on memoryfield.pages (field, status);

-- pages deleted by some machine land here instead of vanishing (cross-machine delete sync)
create table if not exists memoryfield.pages_deleted (
  field      text not null,
  slug       text not null,
  uuid       text,
  title      text,
  body       text,
  sha256     text,
  deleted_by text,
  deleted_at timestamptz default now(),
  primary key (field, slug)
);

create table if not exists memoryfield.sync_runs (
  id          bigserial primary key,
  field       text,
  host        text,
  started_at  timestamptz,
  finished_at timestamptz,
  scanned     integer,
  upserted    integer,
  pulled      integer default 0,
  conflicts   integer default 0,
  tombstoned  integer,
  mode        text,            -- push | pull | sync
  ok          boolean,
  note        text
);
