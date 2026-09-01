# Changelog

All notable changes to the DenoGenesis frontend will be documented in this file.

## [Unreleased]

### Security
- **Deployment hardened to match the `pmd-web-app` model (`deploy/deploy.sh`, replacing `deploy/setup-vps.sh`).** The app no longer runs as the login user that owns the checkout: `deploy.sh` creates a shell-less, home-less `dgweb` system account, makes the checkout `<owner>:dgweb` group-read-only (so a bug in the request path cannot rewrite the code executed at the next restart), and re-asserts `data/` as `dgweb:<owner-group>` setgid `2770` so only the KV database is writable. The systemd unit (`deploy/systemd/denogenesis.service`) is now a strict sandbox — `ProtectSystem=strict`, `ProtectHome=tmpfs`, `SystemCallFilter=@system-service`, empty `CapabilityBoundingSet`/`AmbientCapabilities`, `RestrictAddressFamilies`, `NoNewPrivileges`, bind mounts that expose the checkout read-only and `data/` read-write and nothing else — and runs `deno run` directly with an explicit allow-list (`--allow-net=127.0.0.1 --allow-read=public,data --allow-write=data --allow-env=HOST,PORT,KV_PATH --cached-only`) instead of `deno task start`. Modules are resolved once at deploy time into `/var/cache/denogenesis/deno` so the service never contacts a registry at runtime.
- **`deploy.sh` is test-gated and idempotent.** It runs `deno task verify` (new task: `fmt --check && lint && check && test`) as the invoking user before touching anything and installs nothing if it fails. Re-running it changes nothing the second time. `--skip-verify`, `--skip-nginx` (implies `--skip-certbot`), `--skip-certbot`, `--skip-fail2ban`, `--staging`, and `--force-renewal` flags; every path/name overridable from the environment (`--help`).
- **No-downtime certificate issuance.** First issuance no longer stops nginx for `certbot --standalone`; `deploy.sh` writes a temporary plaintext challenge-only vhost, issues via `--webroot --keep-until-expiring`, then swaps in the real config. Installs a `renewal-hooks/deploy` script that reloads nginx and enables `certbot.timer`.
- **`deploy/nginx/00-default-drop`** (new): box-wide catch-all that closes the connection (`444` / `ssl_reject_handshake`) on requests to no known `server_name`, and owns the `ssl`/`http2` options for `:443`. `denogenesis.com.conf` now uses bare `listen 443;` and inherits them — which also enables HTTP/2, previously omitted because of the shared-socket conflict.
- **`deploy/fail2ban/`** (new): the `nginx-probes` filter and a `jail.local` template (`backend = polling`, bans on `:80`/`:443`) that ban the source IPs behind the scanner probes `deny-probes.conf` already logs. `deploy.sh` installs the filter every run and `jail.local` only when absent, then verifies the jail is reading the access logs.
- **Health check now exercises the write path**: after `/healthz`, `deploy.sh` does one idempotent `POST /api/waitlist` so a service that can serve pages but not write its KV database fails the deploy instead of surfacing days later.
- Nginx edge hardening ported from the msmokc.org template: every vhost now includes `snippets/deny-probes.conf` (shipped in `deploy/nginx/snippets/`), which closes the connection (`444`) on PHP/WordPress/dotfile scanner probes while keeping them logged for fail2ban. A dedicated `:443` vhost 301-redirects `www.denogenesis.com` to the bare apex, and the `:80` vhost now redirects straight to `https://denogenesis.com` (canonical host in one hop) instead of `https://$host`. The example's `add_header` security-header block was deliberately *not* ported: the app already emits stricter versions of those headers (e.g. `X-Frame-Options: DENY` vs `SAMEORIGIN`), and duplicating them at the edge would produce conflicting double headers.

- TLS enabled at the Nginx edge: the shipped `deploy/nginx/denogenesis.com.conf` now terminates HTTPS (TLS 1.2/1.3, Mozilla "intermediate" ciphers), 301-redirects all HTTP to HTTPS, and keeps an HTTP `/.well-known/acme-challenge/` carve-out for zero-downtime certbot renewals. The app's conditional HSTS now activates automatically. README documents the certbot bootstrap (DNS prerequisites, first issuance, webroot renewal). (OCSP stapling and the `http2` listen option were omitted: Let's Encrypt certs no longer carry an OCSP URL, and `http2` conflicts with another vhost sharing `:443`.)
- The waitlist write path is the only place `POST` is allowed. The app permits `POST` solely on `/api/waitlist` (static and `/healthz` stay `GET`/`HEAD`), and Nginx restricts `POST` to a dedicated `location /api/` with a tighter rate limit (`2r/s`) and a `2k` body cap. Deno write access is scoped to `--allow-write=data` (the KV directory only).
- Scoped Deno read permissions: the `start` task now runs with `--allow-read=public` (only the served directory) and `dev` with `--allow-read=.`, replacing unrestricted `--allow-read`. Module/config loading is runtime-privileged and unaffected, so the running process can no longer read anything outside `public/` — an OS-level backstop to the path-traversal gate. The scope is relative to `deno.json`, so it stays location-independent.
- Explicit path-traversal containment gate in `src/static.ts` using `@std/path` (`resolve` + `SEPARATOR`): the request path is decoded, resolved against the root, and must stay within it before `serveDir` runs. Catches `..`, percent-encoded (`%2e%2e`, `%2f`), NUL-byte, and malformed-encoding attempts as defense-in-depth on top of `serveDir`. Covered by `src/static_test.ts`.
- Strict `Content-Security-Policy` scoped to the site's real dependencies (cdnjs for anime.js, Google Fonts) with no `unsafe-inline`/`unsafe-eval`, plus `frame-ancestors 'none'`, `object-src 'none'`, and `base-uri 'self'`.
- Added `Permissions-Policy` denying unused browser features, `Cross-Origin-Opener-Policy`, and `Cross-Origin-Resource-Policy`.
- `Strict-Transport-Security` emitted only when the edge forwards `X-Forwarded-Proto: https`, so HTTPS is pinned in production without affecting plain-HTTP local testing.
- `src/static.ts` now sets `showDotfiles: false` and `showDirListing: false` explicitly, so dotfiles (`.env`, `.git`) and directory indexes are never served from `public/`.
- Nginx hardening: `server_tokens off`, `client_max_body_size 16k`, per-IP rate limiting (`limit_req`), and `limit_except GET HEAD` to reject unsafe methods at the edge.
- Added `src/http_test.ts` covering the security headers, CSP contents, conditional HSTS, and the method guard; new `deno task test`.

### Added
- `deploy/deploy.sh` (replaces `deploy/setup-vps.sh`): a full port of `pmd-web-app`'s `scripts/deploy.sh` — preflight, verify gate, `dgweb` service account, ownership rework, `/etc/denogenesis/denogenesis.env` from `deploy/systemd/denogenesis.env.example`, pre-populated module cache, per-host systemd unit rewrite, loopback + write-path health checks, no-downtime ACME bootstrap, `00-default-drop` + probe snippet + site vhost, and the fail2ban filter/jail. All output goes to stderr so stdout stays pipeable.
- `deno task verify` — `deno fmt --check && deno lint && deno check main.ts && deno test`, the gate `deploy.sh` runs before it installs anything.
- Gzip compression at the Nginx edge (`gzip_vary`, 1 KB minimum, text/CSS/JS/JSON/XML/SVG types) — the Deno app serves everything uncompressed.
- `deploy/nginx/snippets/deny-probes.conf` scanner-probe snippet; README install runbook now copies it to `/etc/nginx/snippets/` before `nginx -t`.
- Documentation header in `deploy/nginx/denogenesis.com.conf` covering assumptions (app port, existing certificate) and an install example.
- **Zod payload validation.** The `POST /api/waitlist` body is now parsed with a Zod schema (JSR `@zod/zod`, new `zod` import) instead of hand-rolled type checks. Wrong-typed fields (`email`/`company` not strings) and non-object bodies are rejected as `400 invalid_request` before touching the store; a missing `email` still falls through to `invalid_email` and the honeypot keeps working for email-less bot posts. Covered by two new tests in `src/waitlist_test.ts`.
- `public/robots.txt` and `public/sitemap.xml` for crawler discovery of `https://denogenesis.com/`.
- **Waitlist backed by Deno KV.** New `src/waitlist.ts` stores founding-member signups in Deno KV with atomic, retry-with-backoff position assignment (concurrent joins never reuse a position), per-email idempotency, email validation, and a honeypot field. Exposed at `POST /api/waitlist` (join → `{status, position, total}`) and `GET /api/waitlist` (live count). Covered by `src/waitlist_test.ts` (20 cases incl. a 25-way concurrency stress test using an in-memory KV).
- **Cinematic landing redesign.** Hero gains a launch badge and a live countdown to the Autumn 2026 launch (mono tabular digits with per-tick animation). A new waitlist section with an animated submit/spinner, drawn-SVG success state showing your cohort position, inline validation, and a live social-proof count. Added a filmic vignette overlay and `prefers-reduced-motion` fallbacks throughout. Loaded JetBrains Mono for the countdown/labels.
- `json()` response helper in `src/http.ts`.
- Systemd service unit for running the Deno app from `/home/sysadmin/.local/src/development/dg-website` on the VPS.
- Nginx reverse proxy config for `denogenesis.com` targeting the Deno app on `127.0.0.1:8004`.
- Deno web app entrypoint using JSR `@std/http/file-server` for the existing site assets.
- Composable server modules for config, HTTP helpers, app assembly, and static asset allowlisting.
- `AGENTS.md` with AI-agent and human maintenance notes.
- README runbook covering Deno tasks, routes, metadata, and architecture.

### Changed
- Moved frontend assets (`index.html`, `main.css`, `script.js`) into a `public/` directory.
- Replaced the explicit static-file allowlist in `src/static.ts` with `@std/http/file-server` `serveDir` serving `public/` via `fsRoot`, so new assets are served without code changes.
- Pointed `siteRoot` in `src/config.ts` at `../public/`.
- Default Deno app port changed to `8004`.
- Replaced the hero GitHub CTA text with `github repo coming soon!`.
- Added a promotional link to `https://pedromdominguez.com`.
- Added HTML metadata for description, author, creator, and robots.

### Fixed
- Hero title not centered on mobile: added `align-items: center` to `.hero-title` in the `max-width: 900px` media query.
- Developer note mission statement invisible on scroll: `.dev-note-mission` container was stuck at `opacity: 0` (CSS) while only inner `.char` spans were animated. Added an opacity flush (delay: 900ms) before the typewriter fires, matching the pattern used for `.hero-sub`.

## [0.1.0] - 2026-03-12

### Added
- Initial project structure for the `denogenesis.com` teaser site.
- `index.html`: Core structure with hero, features, and OKC pride sections.
- `main.css`: Modern dark-theme styling with custom cursor, responsive layout, and glassmorphism effects.
- `script.js`: Interactive animations powered by `anime.js`, including:
    - Custom mouse-follower cursor.
    - Staggered hero entrance animations.
    - Floating background blobs.
    - Scroll-triggered feature grid animations.
    - Dynamic countdown timer for the teaser launch.
- `README.md`: Project overview, tech stack details, and developer credits.
- `CHANGES.md`: Initial changelog tracking.

### Changed
- Adjusted hero title (`.glitch-text`) font size and added `max-width` to `.hero-content` to prevent layout overflow.
- Improved mobile centering for hero content.

## [0.1.2] - 2026-03-12

### Changed
- `index.html`: Split hero `h1.glitch-text` into two separate `span.glitch-text` elements ("DENO" / "GENESIS") inside a `.hero-title` wrapper so each word renders on its own line and the glitch pseudo-elements align correctly.
- `main.css`: Added `.hero-title` flex-column wrapper; set `.glitch-text` to `display: block`.

## [0.3.0] - 2026-03-15

### Added
- `index.html`: New `.dev-note` section replacing the countdown — cathedral-edition developer manifesto by Pedro M. Dominguez. Contains: CSS gothic arch crown, rotating ✦ scripture ornament, large italic quote ("For many are called, few are chosen." — Matthew 22:14), tribute block to St. Joseph Old Cathedral (OKC, Est. 1903), stained-glass ✛ cross divider, developer name/role/mission, gradient-border CTA pill with pulsing ring.
- `main.css`: Full `.dev-note` cathedral component — indigo vault + gold halo + nave-pillar atmosphere via layered radial gradients + repeating-linear-gradient; `.cathedral-arch` gothic arch ornament with double-border + `arch-glow` keyframe; `.scripture-ornament` slow-spin animation; `.scripture-quote` gold gradient text with `gradient-shift`; `.cathedral-tribute` with `tribute-shimmer` keyframe on St. Joseph name; `.stained-divider` gold line + ✛ cross glyph; `.dev-note-mission` starts at opacity:0 for typewriter reveal; `.dev-note-cta` gradient border-box pill with `.cta-pulse` ring.
- `main.css`: New keyframes — `arch-glow`, `ornament-rotate`, `tribute-shimmer`.
- `script.js`: IntersectionObserver on `.dev-note` — stagger-animates all blocks in on scroll entry, then typewriters mission statement (28ms/char, no cursor kept).

### Removed
- `index.html`: Countdown timer section (`.teaser-footer`, `.countdown`, `.count-item`, `.count-sep`).
- `main.css`: All countdown styles and `@keyframes count-pulse`, `count-sweep`, `sep-pulse`.
- `script.js`: `targetDate`, `updateCountdown()`, `setInterval`, teaser observer block.

## [0.2.0] - 2026-03-15

### Added
- `main.css`: Full CSS overhaul — OKC spirit palette (`--okc-sunset` #f97316, `--okc-sky`, `--okc-gold`), expanded design token system, `::selection` accent styling, custom webkit scrollbar (gradient thumb), `body::before` ambient radial glow layers.
- `main.css`: AnimeJS typewriter CSS system — `.char` (per-letter span, opacity:0), `.typewriter-cursor` (blinking 2.5px green bar with glow), `@keyframes cursor-blink`.
- `main.css`: New keyframes — `cursor-pulse`, `follower-spin`, `nav-shimmer`, `badge-pulse`, `dot-blink`, `okc-aurora`, `gradient-shift`, `count-pulse`, `count-sweep`, `sep-pulse`, `logo-glow`, `shimmer`, `pulse-glow`.
- `main.css`: Conic-gradient rotating `.cursor-follower` ring with hue-rotate animation.
- `main.css`: Card diagonal shimmer sweep on hover (`.card::after`, `.feature-item::after`).
- `main.css`: OKC Pride animated 6-stop gradient heading (sunset → gold → green → indigo → pink → sunset) with `background-position` shift animation.
- `main.css`: Oklahoma sunset aurora radial gradient on `.okc-pride::before` with slow scale breathe.
- `main.css`: Countdown enhancements — tri-color top border sweep animation, `count-pulse` glow breathe on numbers, `:` separator styling (`.count-sep`).
- `main.css`: Pre-title upgraded to pill badge with pulsing glow border and animated green dot.
- `main.css`: Gradient nav bottom border (`accent → secondary → okc-sunset`) with sweep animation.
- `main.css`: Footer gradient text + enhanced top border.
- `script.js`: `typewriteElement(el, startDelay, charDelay, keepCursor)` — splits text into `.char` spans, animates opacity via AnimeJS stagger.
- `script.js`: Typewriter applied to `.hero-sub` (2200ms delay, 22ms/char), `.section-header p` (IntersectionObserver, 30ms/char), `.teaser-footer h2` (IntersectionObserver, 55ms/char).
- `index.html`: Countdown `:` separators as `.count-sep` spans between count-items.

### Changed
- `main.css`: Glitch animation enhanced with `skewX` distortion on each frame keyframe for more aggressive feel.
- `main.css`: Blobs upgraded to `radial-gradient` fills (solid color → transparent) with 3-phase float keyframes.
- `main.css`: `.primary-btn` and `.cta-btn` upgraded to gradient backgrounds with shimmer `::before` overlays.
- `main.css`: `.feature-item` initial `opacity: 0` (AnimeJS reveals on scroll).
- `script.js`: Hero subtitle typewriter replaces old `.hero-sub` opacity fade in timeline.
- `script.js`: Blob animation uses `easeInOutSine` easing with 3-phase float.

## [0.1.1] - 2026-03-12

### Changed
- `main.css`: Major visual overhaul — refined color palette (deeper bg, indigo secondary, improved muted fg), noise grain overlay, hero grid-line pattern, floating blob CSS keyframe animations, enhanced glassmorphism on nav and cards, gradient border accents on feature items and countdown, individual accent colors per stack card via CSS custom properties, scroll-progress bar styles, tighter typography (letter-spacing, improved clamp sizes).
- `index.html`: Added scroll progress bar element, `data-label` attributes on countdown items (used by CSS `::after` for labeling), removed inline letter suffixes from countdown spans.
- `script.js`: Wired scroll progress bar width to page scroll position.
