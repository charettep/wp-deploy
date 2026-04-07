# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single self-contained bash script (`wp-deploy.sh`) that deploys, manages, backs up, and destroys WordPress instances in Docker, exposed publicly via Cloudflare Tunnel. No build step, no dependencies beyond bash 4+.

## Running and testing the script

```bash
# Syntax check (no execution)
bash -n wp-deploy.sh

# Run deploy flow
bash wp-deploy.sh

# Run via curl (for remote machines)
bash <(curl -fsSL https://raw.githubusercontent.com/charettep/wp-deploy/main/wp-deploy.sh)

# Lifecycle commands
bash wp-deploy.sh --list
bash wp-deploy.sh --stop <name>
bash wp-deploy.sh --start <name>
bash wp-deploy.sh --destroy <name>
bash wp-deploy.sh --backup <name>
bash wp-deploy.sh --restore <name> <file>
```

Run as a **normal user with passwordless sudo** — not as root. The script calls `sudo` internally. Running as root breaks `$HOME`-based paths and the `usermod -aG docker $USER` step.

## Pre-seeding interactive prompts

Copy `.env.template` to `.env` in the same directory. Any key set there skips its corresponding `read` prompt. Key variables: `INSTANCE_NAME`, `WP_PORT`, `DOMAIN`, `CF_HOSTNAME`, `WP_ADMIN_EMAIL`, `WP_ADMIN_PASSWORD`, `WP_LOCALE`, `WP_TIMEZONE`.

## Architecture

The script is one file (~2400 lines) structured as a collection of functions dispatched by `main()` at the bottom.

### Deploy flow (default, no args)

`cmd_deploy` calls these in order:
1. `detect_system` — sources `/etc/os-release`, sets `DISTRO_ID`, `PKG_MANAGER`, `ARCH`
2. `check_dependencies` — apt full-upgrade, installs docker/openssl/curl/jq, adds user to docker group
3. `setup_cloudflared` — 5-flag idempotency check (installed / cert / tunnel JSON / service enabled / config file); each missing step runs independently
4. `prompt_instance_config` — all interactive `read` prompts; checks `GLOBAL_CONFIG[]` map first
5. `setup_directories` — creates `~/wordpress-instances/$INSTANCE_NAME/{wp-data,db-data,backups}`, sets `LOG_FILE`
6. `generate_credentials` — writes `/root/wp-creds/$INSTANCE_NAME/.env` with random MySQL passwords, salts, and the `WP_CONFIG_EXTRA` PHP block
7. `generate_compose` — writes `docker-compose.yml` from a heredoc
8. `deploy_containers` — `sudo docker compose pull` then `up -d`
9. `wait_for_mysql` / `wait_for_wordpress` — poll with timeout
10. `run_wp_cli_install` — runs `wordpress:cli` container via `sudo docker run --volumes-from`
11. `finalize_cloudflared` — `cf_route_dns` + `cf_append_ingress` + `systemctl restart cloudflared`
12. `verify_all_endpoints` — polls local and public URLs until all return 2xx/3xx
13. `print_final_report`

### Key data flow

- `GLOBAL_CONFIG[]` — associative array loaded from `.env` file by `load_global_env_config`; checked before every `read` prompt via `global_config_has_value` / `global_config_get`
- Credentials are written to `/root/wp-creds/$INSTANCE_NAME/.env` (root-owned, mode 600)
- `dc()` helper — copies creds to a temp file, runs `sudo docker compose --env-file`, cleans up; used for all compose operations
- `WP_CONFIG_EXTRA` — PHP code injected into `wp-config.php` by the WordPress Docker image via the `WORDPRESS_CONFIG_EXTRA` env var. Dollar signs must be escaped as `\$` in bash strings and then doubled to `$$` by `escape_compose_dollars` so Docker Compose passes them through as literal `$` to PHP.

### Cloudflare tunnel state machine (`setup_cloudflared`)

Checks 5 boolean flags independently. Fast path returns immediately if all are true. Otherwise runs only the missing steps:
1. Binary installed → `install_cloudflared` (apt repo for Debian/Ubuntu; binary download for others)
2. `/root/.cloudflared/cert.pem` exists → `cf_login` (interactive browser OAuth)
3. UUID-shaped `.json` in `/root/.cloudflared/` exists → `cf_create_tunnel`
4. `config.yaml` exists → `cf_write_initial_config` (uses `$TUNNEL_NAME.$DOMAIN → localhost:8080`)
5. `systemctl is-enabled cloudflared` → `cf_install_service`

Per-instance ingress is managed in `finalize_cloudflared` (step 11), not here. `cf_append_ingress` edits both `/etc/cloudflared/config.yaml` and `/root/.cloudflared/config.yaml`.

### Docker calls all require sudo

Users are not in the `docker` group until after first install + re-login. Every docker socket call is prefixed with `sudo`: `sudo docker compose`, `sudo docker exec`, `sudo docker run`, `sudo docker ps`, `sudo docker info`.

### Progress display

`step N "message"` updates the global progress bar (calculated from `TOTAL_STEPS=16`). `print_success/error/warn/info` each call `clear_progress_bar`, print a coloured line, then re-render the bar. Don't call `echo` directly for user-facing output — use these helpers.

## Target platforms

| Host | Distro | Arch |
|------|--------|------|
| sp4 (192.168.0.95) | Ubuntu 22.04 LTS | x86_64 |
| t5500 (10.42.0.18) | Ubuntu 22.04 LTS | x86_64 |
| pix8 (100.103.165.74 Tailscale) | Debian 13 trixie | aarch64 |
| pix10 (100.106.169.19 Tailscale) | Debian 13 trixie | aarch64 |

Both distros are apt-based, so all package management takes the `apt` branch. `dig` is absent on pix8/pix10 — the DNS retry path in `resolve_authoritative_ipv4` degrades gracefully.

## File layout at runtime

```
~/wordpress-instances/<name>/
  docker-compose.yml
  deploy.log
  wp-data/          # WordPress files (owned by www-data uid 33)
  db-data/          # MySQL data files
  backups/

/root/wp-creds/<name>/
  .env              # All secrets + WP_CONFIG_EXTRA (mode 600)

/root/.cloudflared/
  cert.pem
  <UUID>.json
  config.yaml

/etc/cloudflared/
  config.yaml       # Managed by cloudflared service install
```
