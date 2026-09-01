# Agent Notes

This repository is a Deno web app for the DenoGenesis teaser site.

## Operating Contract

- Runtime: Deno 2.x.
- HTTP dependency: JSR `@std/http`.
- Validation dependency: JSR `@zod/zod` (Zod 4); API request bodies are parsed
  with a schema in the route module that owns them.
- Public routes: `/healthz`, `/api/waitlist` (GET count, POST join), plus any
  file under `public/` (`/`, `/index.html`, `/main.css`, `/script.js`,
  `/robots.txt`, `/sitemap.xml`).
- Persistence: Deno KV (`src/waitlist.ts`), default `./data/waitlist.db`,
  overridable via `KV_PATH`. `kv` unstable flag is set in `deno.json`.
- Default app bind: `127.0.0.1:8004`.
- Public site: `https://denogenesis.com`. Nginx terminates TLS and proxies to
  `127.0.0.1:8004`; HTTP is 301-redirected to HTTPS.
- VPS repo path: `/home/sysadmin/.local/src/development/dg-website`.
- Server entrypoint: `main.ts`.
- Frontend assets live in `public/` and are served directly via `fsRoot`.

## Architecture

- `main.ts` starts the process, opens Deno KV, and does no request handling.
- `src/config.ts` reads `HOST`, `PORT`, and `KV_PATH`.
- `src/http.ts` contains composable request handlers and middleware.
- `src/static.ts` serves the `public/` directory via `serveDir` `fsRoot`, gated
  by an explicit `@std/path` traversal check (`isPathWithinRoot`).
- `src/waitlist.ts` holds the Deno KV waitlist store and its HTTP handlers.
- `src/app.ts` assembles the app from the small functions above.
- `deploy/nginx/denogenesis.com.conf` contains the production reverse proxy;
  `deploy/nginx/00-default-drop` is the box-wide catch-all it depends on.
- `deploy/systemd/denogenesis.service` is the production unit (hardened sandbox,
  runs as the `dgweb` system account); `deploy/systemd/denogenesis.env.example`
  is the `/etc/denogenesis/denogenesis.env` template.
- `deploy/deploy.sh` installs all of it on the VPS in one idempotent, test-gated
  run; `deploy/fail2ban/` holds its `nginx-probes` filter and `jail.local`.

Keep additions small, explicit, and composable. Prefer one function that does
one job over shared state or hidden framework behavior.

## Security Rules

- `src/http.ts` owns the security headers. The `Content-Security-Policy` is
  strict and has no `unsafe-inline`/`unsafe-eval`. Adding an inline
  `<script>`/`<style>`, an inline event handler, or a new third-party origin
  requires a matching CSP change in the same file — otherwise the browser will
  block the asset.
- Do not weaken the CSP with `unsafe-inline`/`unsafe-eval` to "make it work";
  move the code into `public/script.js` or add the specific origin instead.
- Everything in `public/` is served publicly. Never place secrets there.
  `serveDir` is configured to refuse dotfiles and directory listings; keep it
  that way.
- HSTS is conditional on `X-Forwarded-Proto: https`; do not make it
  unconditional.
- `src/static.ts` gates every request through `isPathWithinRoot` before
  `serveDir`; keep that check (and its tests) in place — it is the explicit
  path-traversal boundary.
- The `start` task reads only `public/` and `data/` and writes only `data/`
  (`--allow-read=public,data --allow-write=data`). If the app ever needs another
  path at runtime, widen this deliberately rather than reverting to unrestricted
  flags.
- `POST` is allowed only on `/api/waitlist`. Static assets and `/healthz` stay
  `GET`/`HEAD`. Keep new write endpoints under `/api/` so the Nginx
  `location
  /api/` rate limit and body cap apply.
- Run `deno task test` after touching `src/http.ts` or `src/static.ts`.

## Content Rules

- GitHub references should remain `github repo coming soon!` until a public repo
  exists.
- Promote Pedro M. Dominguez's personal/business site at
  `https://pedromdominguez.com`.
- Preserve the existing OKC/DenoGenesis voice unless the user asks for a copy
  rewrite.

## Commands

- Check: `deno task check`
- Format: `deno task fmt`
- Lint: `deno task lint`
- Develop: `deno task dev`
- Start: `deno task start`
- Test: `deno task test`
- Verify: `deno task verify` (the gate `deploy/deploy.sh` runs)
