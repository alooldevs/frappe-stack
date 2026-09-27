# frappe-stack: Docker mode

Continues from [README](README.md) steps 1–5, with `host-prep.sh docker`. One shared **Traefik** (HTTPS via
Let's Encrypt), one shared **MariaDB 11.8**, and one image per bench with its apps baked in. The layout is
frappe_docker's single-server setup (pinned at `3d0a0e5`), driven by `bin/stack`.

```
Internet :80/:443 → Traefik ─┬→ alpha: nginx → gunicorn · websocket · workers · scheduler · redis×2
                             └→ beta: …
                    MariaDB (private network, never published)
```

**6. Shared services** (2 min)
```sh
stack init you@example.org                   # MariaDB + Traefik + nightly backup cron
```

**7. First bench** (2 min to set up, ~5 min to build)
```sh
stack new-bench alpha erp.example.org
nano ~/stack/benches/alpha/build.env         # which Frappe, see "Choosing Frappe and apps"
nano ~/stack/benches/alpha/apps.json         # which apps
stack build alpha
stack up alpha
```

**8. First site** (3 min)
```sh
stack site alpha erp.example.org orgwise deck
```
This creates the site and installs the apps. It turns on the scheduler, sets `host_name`, routes the
domain, and waits until HTTPS answers with a valid certificate. Then it prints where the Administrator
password is (`~/stack/env/alpha.passwords`).
Log in and finish the setup wizard. Set the **time zone** there, because a new site starts on Asia/Kolkata.

## Choosing Frappe and apps

`benches/<bench>/build.env`:
```sh
FRAPPE_PATH=https://github.com/frappe/frappe          # public upstream
FRAPPE_BRANCH=version-16
# FRAPPE_PATH=git@github-ACCOUNT:OWNER/frappe.git     # a private fork, through a step 4 alias
# FRAPPE_BRANCH=BRANCH
PYTHON_VERSION=3.14                                   # version-16 and develop need 3.14 and Node 24
NODE_VERSION=24
```
`benches/<bench>/apps.json`:
```json
[
  { "url": "git@github-ACCOUNT:OWNER/app_one.git", "branch": "develop" },
  { "url": "https://github.com/frappe/some_public_app", "branch": "main" }
]
```
Private repos use the `github-ACCOUNT` alias, never a token in the URL; `stack build` refuses tokens.
The build receives only the SSH keys that bench uses, as a secret. They are gone before the image is saved.

## Day to day

| Task | Command |
|---|---|
| What's running | `stack ps` |
| Any bench command | `stack bench alpha --site erp.example.org migrate` |
| Shell in a bench | `stack sh alpha` |
| Logs | `stack logs alpha backend` · `stack logs traefik` |
| Restart a bench | `stack restart alpha` (or one service: `stack restart alpha backend`) |
| Update apps (new commits) | `stack build alpha && stack up alpha && stack bench alpha --site all migrate` |
| Add a site | point DNS, then `stack site alpha new.example.org app_one` |
| Add a bench | `stack new-bench beta x.example.org` → edit → `stack build beta && stack up beta && stack site beta x.example.org …` |
| Backup now | `stack backup` (nightly at 02:00 UTC; log in `~/stack/logs/backup.log`) |

Never run `bench build`, `bench get-app` or `bench update` inside a container. Apps and assets live in the
image, so every change goes through `stack build`.

## Files

| Path | What | In git |
|---|---|---|
| `bin/stack` | the Docker-mode command | yes |
| `bootstrap/host-prep.sh` | one-time host setup (`docker` or `native`) | yes |
| `base/` | Traefik (upstream minus dashboard), MariaDB tuning | yes |
| `templates/` | what `new-bench` copies | yes |
| `benches/<bench>/` | build.env, apps.json, patched Containerfile, build logs | no |
| `env/` | settings, secrets, generated passwords (mode 600) | no |
| `compose/` | rendered compose files, what's actually running | no |
| `overrides/<name>.yaml` | optional per-server tweak, appended to that stack | no |
| `frappe_docker/` | upstream, checked out at the pinned commit | no |

## Good to know

- **Builds are heavy for this VM.** B-series VMs sustain 40% of their CPU and burst on banked credits, and
  builds use them up. Check *CPU Credits Remaining* in the Azure portal before several builds in a row.
  Saving the 3 GB image also maxes out a 64 GiB disk for about a minute; the sites slow down and SSH can
  drop. Run builds inside `tmux` so a dropped connection doesn't kill them.
- **Memory** (measured): a bench idles at about 370 MB, MariaDB at about 410 MB, Traefik at about 25 MB.
  CPU runs out before RAM does.
- **Docker ignores ufw.** The Azure network security group (NSG) is the firewall. Only Traefik publishes
  ports.
- **Backups stay on this disk.** They protect against app mistakes, not against losing the VM. Copy them
  off-site yourself.
- **Unstyled UI after an update** (CSS 404s, JS fine) means the bench-wide asset map cached in Redis
  (`assets_json`) is from the previous image. `stack up` clears it when the image changes. To clear it by hand:
  `docker compose -p alpha -f ~/stack/compose/alpha.yaml exec redis-cache redis-cli del assets_json && stack restart alpha backend`.
  `bench clear-cache` doesn't touch this key.
- **Disk after updates.** The previous bench image stays behind (about 3 GB). List them with
  `docker image ls 'stack/*'` and remove old tags with `docker image rm stack/alpha:<old-tag>`.
  The build cache grows too: check it with `docker buildx du` and trim it with
  `docker buildx prune --keep-storage 10GB`.
- **Moving to a newer frappe_docker:** bump `FRAPPE_DOCKER_REF` in `bin/stack`, then `stack init` and
  `stack build <bench>`. The build stops with a clear message if upstream's Containerfile changed shape.
