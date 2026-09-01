# DenoGenesis

DenoGenesis is a Deno-powered teaser site for democratizing web development in
Oklahoma City and beyond. The frontend files are intentionally simple:
`public/index.html`, `public/main.css`, and `public/script.js` remain the source
of the visible site, while Deno provides the HTTP process around them.

Pedro M. Dominguez is the developer and architect behind the project. Personal
and business work is available at https://pedromdominguez.com.

## Run

```sh
deno task dev
```

The dev task starts the app with file watching on `http://127.0.0.1:8004/`.

```sh
deno task start
```

Set `HOST` or `PORT` to override the default bind address:

```sh
HOST=0.0.0.0 PORT=8080 deno task start
```

For production, keep the Deno process on loopback and let Nginx handle public
traffic for `denogenesis.com`:

```sh
deno task start
```

## Deploy

The whole install is one idempotent script. It runs the test suite first and
installs nothing if it fails, so a broken tree cannot reach the server:

```sh
sudo deploy/deploy.sh
```

Updating is `git pull && sudo deploy/deploy.sh --skip-certbot`. Flags:
`--skip-verify` (redeploy an already-verified tree), `--skip-nginx` (proxy lives
elsewhere; implies `--skip-certbot`), `--skip-certbot`, `--skip-fail2ban`,
`--staging` (Let's Encrypt staging CA), `--force-renewal`. Every path and name
is overridable from the environment — see `deploy/deploy.sh --help`.

Prerequisites: `deno` at `/usr/bin/deno` (a real file, not a `~/.deno` symlink —
the unit's `ProtectHome=tmpfs` hides `/home`), `nginx`, `certbot`, and
`fail2ban` installed; DNS A/AAAA records for `denogenesis.com` and
`www.denogenesis.com` pointing at the VPS; ports 80/443 open.

What it does, in order, each step idempotent:

1. **Verify** — `deno task verify` (fmt, lint, type check, tests) as the
   invoking user. Nothing is installed if it fails.
2. **Account** — a `dgweb` system user with no shell, no home, no password.
3. **Ownership** — the checkout becomes `<you>:dgweb`, group read-only, so the
   running service cannot rewrite the code it executes. `data/` is re-asserted
   `dgweb:<your-group>` (setgid `2770`) so the service can write the KV database
   and you can still read it.
4. **Environment** — `/etc/denogenesis/denogenesis.env` from the example, only
   if absent (it is the one file meant to diverge from git).
5. **Module cache** — `deno cache main.ts` into `/var/cache/denogenesis/deno`,
   so the unit runs `--cached-only` and never contacts a registry at runtime.
6. **Service** — `deploy/systemd/denogenesis.service` with its placeholder
   paths/user rewritten for this host, then `daemon-reload` + `restart`. The
   unit is a hardened sandbox (`ProtectSystem=strict`, `ProtectHome=tmpfs`,
   `SystemCallFilter=@system-service`, empty `CapabilityBoundingSet`, bind
   mounts for the checkout read-only and `data/` read-write).
7. **Health** — polls `127.0.0.1:8004/healthz`, then does one real
   `POST /api/waitlist` (idempotent per email) to prove the KV store is
   writable. A failure prints the `chown` that fixes it.
8. **Certificates** — webroot issuance via `certbot`, no downtime. On a host
   with no lineage yet it writes a temporary plaintext challenge-only vhost,
   issues, then step 9 replaces it. Installs a renewal deploy-hook that reloads
   nginx and enables `certbot.timer`.
9. **Reverse proxy** — installs `deny-probes.conf`, the box-wide
   `00-default-drop` catch-all (which owns `ssl`/`http2` for `:443`; removes the
   distro `default` site), and `denogenesis.com.conf`, then `nginx -t` and
   reload.
10. **fail2ban** — the repo's `nginx-probes` filter, plus `jail.local` only if
    absent (it carries the real sshd port, which is not in git). Restarts
    fail2ban and checks the jail is reading the access logs, not the journal.

```sh
journalctl -u denogenesis -f
sudo systemctl status denogenesis
sudo fail2ban-client status nginx-probes
```

HTTP and `www.denogenesis.com` are 301-redirected to the canonical
`https://denogenesis.com`, and the app emits `Strict-Transport-Security`
automatically once requests arrive with `X-Forwarded-Proto: https`.

## Check

```sh
deno task check
deno task fmt
deno task lint
deno task test
deno task verify   # fmt --check, lint, check, test — the gate deploy.sh runs
```

## Security

The app follows OWASP secure-defaults for a static site:

- A strict `Content-Security-Policy` allows only the origins the site uses
  (`cdnjs.cloudflare.com` for anime.js, Google Fonts) with no `unsafe-inline` or
  `unsafe-eval`. Adding an inline `<script>`/`<style>` or a new CDN requires
  updating the policy in `src/http.ts`.
- `Permissions-Policy`, `Referrer-Policy`, `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy`, and
  `Cross-Origin-Resource-Policy` are set on every response.
- Nginx terminates TLS (TLS 1.2/1.3, Mozilla "intermediate" ciphers) and
  301-redirects all HTTP to HTTPS. `Strict-Transport-Security` is sent by the
  app only when the request arrives with `X-Forwarded-Proto: https`, so it
  activates automatically behind the HTTPS proxy.
- `serveDir` runs with `showDotfiles: false` and `showDirListing: false`, so
  dotfiles and directory indexes are never exposed from `public/`.
- An explicit path-traversal gate (`isPathWithinRoot` in `src/static.ts`, built
  on `@std/path`) decodes and resolves each request path and rejects anything
  that would escape `public/` — including `..` and percent-encoded variants —
  before `serveDir` runs.
- Nginx adds `server_tokens off`, a request-body cap, per-IP rate limiting, and
  rejects non-`GET`/`HEAD` methods at the edge.
- A shared `snippets/deny-probes.conf` (shipped in `deploy/nginx/snippets/`)
  closes the connection (`444`) on PHP/WordPress/dotfile scanner probes in every
  vhost, keeping them logged so fail2ban can ban the source IP.
- `POST` is permitted only on `/api/waitlist` (app) and a dedicated Nginx
  `location /api/` with a tighter rate limit and a `2k` body cap. Deno write
  access is scoped to the KV directory (`--allow-write=data`).
- The `start` task runs with `--allow-read=public` so the process can only read
  the served directory (module/config loading is runtime-privileged and
  unaffected). This is an OS-level backstop to the traversal gate. The scope is
  relative to `deno.json`, so it is independent of where the repo is deployed.

## Architecture

The server follows a small, composable shape:

- `main.ts` starts Deno and owns process-level concerns.
- `src/config.ts` reads environment configuration.
- `src/http.ts` defines request handlers, middleware (including the security
  headers and method guard), routing helpers, and response helpers.
- `src/static.ts` uses JSR `@std/http/file-server` `serveDir` to serve the
  `public/` directory directly via `fsRoot`.
- `src/waitlist.ts` stores founding-member signups in Deno KV and exposes the
  `/api/waitlist` join (`POST`) and count (`GET`) handlers. The `POST` body is
  validated against a Zod schema (JSR `@zod/zod`) before it reaches the store.
- `src/app.ts` assembles the health route, waitlist route, static file route,
  security headers, method guard, and request logging.
- `deploy/systemd/denogenesis.service` runs the Deno app from the checkout as a
  shell-less `dgweb` system account inside a strict systemd sandbox. It carries
  placeholder paths for the machine it was written on; `deploy/deploy.sh`
  rewrites `WorkingDirectory`, the bind mounts, and `User`/`Group` per host.
- `deploy/systemd/denogenesis.env.example` is the template for the optional
  `/etc/denogenesis/denogenesis.env` override file (never in git).
- `deploy/nginx/denogenesis.com.conf` reverse proxies `denogenesis.com` to the
  Deno process at `127.0.0.1:8004`, gzips text responses at the edge, and
  301-redirects HTTP and `www.denogenesis.com` to the canonical HTTPS apex. Its
  `listen 443;` lines are bare — `ssl`/`http2` are set once in
  `deploy/nginx/00-default-drop`, the box-wide catch-all that also closes the
  connection on requests to no known `server_name`.
- `deploy/fail2ban/` holds the `nginx-probes` filter and a `jail.local` template
  that bans the IPs behind scanner probes.
- `deploy/deploy.sh` applies all of the above on the VPS in one idempotent run,
  test-gated, with privilege separation, a no-downtime ACME bootstrap, and
  `--skip-*` flags. See the Deploy section above.

Public routes:

- `GET /healthz`
- `GET /` and any file under `public/` (e.g. `/index.html`, `/main.css`,
  `/script.js`, `/robots.txt`, `/sitemap.xml`), served directly from the
  `public/` directory.
- `GET /api/waitlist` — returns the current waitlist count as JSON.
- `POST /api/waitlist` — joins the waitlist with a JSON `{ "email": "..." }`
  body; returns `{ status, position, total }`.

`HEAD` is allowed for the read paths. `POST` is allowed only on `/api/waitlist`.
Other methods return `405`.

## Waitlist (Deno KV)

The waitlist persists to Deno KV (`src/waitlist.ts`). The store path defaults to
`./data/waitlist.db` and is overridable with `KV_PATH`. Positions are assigned
atomically with optimistic retry, so concurrent signups never collide, and joins
are idempotent per email. The KV data directory is git-ignored. The `start` task
grants `--allow-write=data` (and reads `public,data`) and enables the `kv`
unstable flag via `deno.json`.

## Content Metadata

- Audience: creators, local builders, and early DenoGenesis followers.
- Location signal: Oklahoma City, Oklahoma.
- GitHub status: github repo coming soon!
- Promotional link: https://pedromdominguez.com

## Agent Notes

See `AGENTS.md` for AI-agent maintenance rules. In short: keep functions
explicit, prefer composition over shared state, preserve the current frontend
assets unless a change is intentional, and remember that every file placed in
`public/` is served publicly.
