# memoryfield-sync (mf-sync)

Sync a **memoryfield** — a directory of Markdown memory pages with YAML frontmatter —
across machines through a [db9](https://db9.ai) database as the hub.

```
machine A  --push/pull-->  db9 database "memoryfield"  <--pull/push--  machine B
```

Single-file Python 3 (stdlib only) + one SQL schema. `db9` CLI and `psql` are the only
dependencies. Nothing else runs on the hub: the pages live in a normal table, so you can
query them with SQL (`memoryfield.pages`) instead of grepping.

## What is a memoryfield

A flat directory of `*.md` pages, each with YAML frontmatter
(`title`, `summary`, `uuid`, `created`, `updated`, optional `status`).
Default location: `~/.memoryfields/work`. See the `local-memoryfield` skill if you use one;
the format requirements here are just: UTF-8, `*.md`, frontmatter delimited by `---`.

## Requirements

- `db9` CLI, logged in (`db9 login`) to the account/project that hosts the database
- `psql` (PostgreSQL client ≥ 14) — mf-sync talks pgwire, it does not use the db9 HTTP SQL API
- `python3` (stdlib only)

## Install

```bash
git clone git@github.com:c4pt0r/memoryfield-sync.git ~/memoryfield-sync
cd ~/memoryfield-sync && ./install.sh          # symlink + systemd user timer (5 min, --sync)
```

`install.sh` flags:

| flag | meaning |
|---|---|
| `--db NAME` | db9 database (default `memoryfield`, env `MEMORYFIELD_DB9`) |
| `--field PATH` | memoryfield dir (default `~/.memoryfields/work`, env `MEMORYFIELD`) |
| `--interval N` | timer period in minutes (default 5) |
| `--no-timer` | install the command only |
| `--cron` | print a crontab line (used automatically if there is no systemd user instance) |
| `--hooks` | append the `mf-sync --sync` hook to `mnew` / `mdream` if you have the memoryfield skill |
| `--skill` | install/refresh `~/.agents/skills/local-memoryfield/SKILL.md` from `skill/SKILL.md` (old copy kept as `.bak.<ts>`) |

It writes `~/.config/memoryfield-sync/env` (sourced by the systemd unit) and symlinks
`mf-sync` into `~/.local/bin`.

### macOS

There is no systemd user instance, so `install.sh` installs a **LaunchAgent** instead
(`~/Library/LaunchAgents/com.c4pt0r.memoryfield-sync.plist`, `StartInterval`, `RunAtLoad`,
logs in `~/.local/state/memoryfield-sync/`). Force it with `--launchd`, or force the crontab
form with `--cron` (cron has a bare `HOME`/`PATH` — `db9` needs `HOME`, or it silently
bootstraps a fresh *anonymous* account, so set both in the cron line).

`psql` usually comes from Homebrew `libpq`, which is keg-only: add `/opt/homebrew/bin` to
`PATH` (the LaunchAgent already does). `mf-sync` also reads
`~/.config/memoryfield-sync/env`, so a bare `mf-sync` works in any shell on that machine.

### Joining from a second machine

Same db9 account, same database, same **field name** (the directory basename is the key):

```bash
db9 status                         # must show the account that owns the database
mkdir -p ~/.memoryfields/work      # or any dir whose basename matches, e.g. "work"
git clone ... && ./install.sh --db memoryfield --field ~/.memoryfields/work
mf-sync --sync --dry-run           # preview before letting it write files
```

A fresh machine needs no field directory: `mf-sync` creates it (`mkdir -p` when the path is
under `$HOME` or its parent exists) and pulls the hub into it. Verified: first run on an empty
machine created the dir and pulled 132 pages byte-identical, the second run was a no-op.

## Commands

```bash
mf-sync                 push local changes only (safe default)
mf-sync --sync          bidirectional: pull, then push          <- what the timer runs
mf-sync --pull          pull only
mf-sync --check         exit 1 if local and hub disagree; also re-hashes bodies server-side
mf-sync --status        rows per host, tombstones, last 5 runs
mf-sync --dry-run       print what --sync would do
mf-sync --full          push every page (repair after a schema rebuild)
mf-sync --with-fs       additionally copy raw .md into the db9 filesystem (/memoryfield/<field>)
mf-sync --strict        non-zero exit on failure (default: warn and exit 0, so hooks never break)
mf-sync --host NAME     identity recorded in `updated_by` (default: hostname)
```

## The memoryfield skill (optional)

`skill/SKILL.md` is the agent-facing instruction file for a memoryfield: how to search
(`msearch`), how to write a page (`mnew`), page rules, and the sync/conflict workflow above.
`./install.sh --skill` copies it into `~/.agents/skills/local-memoryfield/SKILL.md`
(backing up whatever was there), so every machine's agent follows the same rules.
Keep it in the repo rather than hand-editing it per machine — that is what makes machine N
behave like machine 1.

## Merge semantics

Remote rows keep `sha256` of the exact file bytes plus `updated_by` (host) and `synced_at`.
Each machine also keeps a local ancestor cache, `<field>/.db9-sync-state.json`
(`slug -> sha256` of the last version both sides agreed on). Every page is then classified:

| local vs ancestor | hub vs ancestor | action |
|---|---|---|
| unchanged | unchanged | nothing |
| unchanged | changed | **pull** (hub wins, file overwritten) |
| changed | unchanged | **push** |
| changed | changed | **conflict**: your file is kept, the incoming version is written to `<field>/.conflicts/<slug>@<other-host>.md`; `--strict` exits non-zero and the conflict repeats every run until you resolve it |
| page absent locally, was known | hub has a tombstone | **push the delete** (goes to `pages_deleted`) |
| page present, unmodified, hub tombstoned by a peer | — | **honor the delete**: the file moves to `<field>/.conflicts/<slug>@deleted.md` and is removed from the field |
| page present, modified, hub tombstoned | — | conflict, your version is re-pushed (resurrection) |

Nothing is ever silently deleted: honored deletes and conflict copies land in
`<field>/.conflicts/`, and every removed page keeps its last body in `memoryfield.pages_deleted`.
`.conflicts/` is a subdirectory, so a `grep`/`msearch` over `$FIELD/*.md` won't pick it up.

## Layout on the hub

Schema `memoryfield`, tables keyed by `(field, slug)` — `field` is the memoryfield directory
basename, so several fields (or several people) can share one database:

- `pages(field, slug, title, summary, status, status_reason, uuid, page_created, page_updated, bytes, sha256, body, updated_by, synced_at)` — `body` is the byte-exact file content, frontmatter included
- `pages_deleted(...)` tombstones with `deleted_by`, `deleted_at`
- `sync_runs(field, host, started_at, finished_at, scanned, upserted, pulled, conflicts, tombstoned, mode, ok, note)`

```sql
-- what other machines changed today
select slug, updated_by, synced_at from memoryfield.pages
 where field='work' and synced_at > now() - interval '1 day' order by synced_at desc;
-- who broke what
select host, mode, ok, conflicts, note from memoryfield.sync_runs
 where field='work' order by id desc limit 20;
```

## db9 / TiKV gotchas (already handled in the code, keep them in mind when patching)

- `decode(hex,'hex')::text` into a `text` column stores the literal `"\x<hex>"` string
  (doubled length, `like '---%'` false). Bodies are inserted as
  `convert_from(decode(hex,'hex'),'UTF8')` — hex is used to dodge quoting/escaping entirely.
- Reading a body back with `text::bytea` fails (`invalid input syntax for type bytea`);
  use `convert_to(body,'UTF8')`.
- `encode(...,'base64')` inserts a newline every 64 characters — strip it with
  `replace(...,chr(10),'')` before treating a row as one line.
- `pg_trgm` is not available (`extension is not available`), so full-text search on the hub is
  `ILIKE` / `to_tsvector('simple', body)` at best. Grep locally.
- `create table if not exists` never adds columns: newer versions need
  `alter table ... add column if not exists`, which mf-sync runs on every invocation.
- The temporary DSN from `db9 db connect <db> --quiet` is a 15-minute token; mf-sync fetches a
  fresh one per run and never writes a password to disk.

## Uninstall

```bash
systemctl --user disable --now memoryfield-db9-sync.timer
rm ~/.config/systemd/user/memoryfield-db9-sync.{service,timer} ~/.local/bin/mf-sync
```
Hub data stays; delete it with `db9 delete <db>` if you want it gone.
