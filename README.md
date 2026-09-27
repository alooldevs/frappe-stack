# frappe-stack

Several Frappe benches on one server with Docker. There is one shared **Traefik** for HTTPS (Let's Encrypt)
and one shared **MariaDB 11.8**. Each bench (`alpha`, `beta`, …) runs its own image with its apps baked in.
The layout is frappe_docker's single-server setup (pinned at `3d0a0e5`), driven by one command: `bin/stack`.

```
Internet :80/:443 → Traefik ─┬→ alpha: nginx → gunicorn · websocket · workers · scheduler · redis×2
                             └→ beta: …
                    MariaDB (private network, never published)
```

## Have these ready

- A domain for the first site, e.g. `erp.example.org`, and access to its DNS
- An email for Let's Encrypt
- The GitHub account(s) holding any private repos: your Frappe fork, your apps
- Which Frappe (repo and branch) and which apps (repo and branch) the first bench gets

## Fresh server → live site (about 45 min)

**1. Create the VM** (Azure portal, 10 min)
- Image **Ubuntu Server 24.04 LTS x64**. Size **Standard_B2as_v2** (2 vCPU, 8 GiB) or larger.
- Authentication: **Password**, temporary. Step 3 replaces it with a key and turns password login off.
- Disks: OS disk **64 GiB**, Premium SSD. The 30 GiB default is too small for images plus build cache.
- Networking: a new **Standard** public IP (static). Inbound ports **22, 80, 443**.
- Note the public IP.

**2. DNS** (2 min): add an A record, `erp.example.org → <public IP>`.

**3. SSH in with a key**, from your Mac with [keyup](https://github.com/alooldevs/keyup) (3 min):
```sh
curl -fsSL https://raw.githubusercontent.com/alooldevs/keyup/main/keyup.sh | bash -s -- server NAME USER@IP
```
Pick **1**, type the VM password once, then answer **y** to turn password login off. After that, `ssh NAME` works.

**4. GitHub access on the server** (3 min per account). Skip this if every repo is public.
```sh
ssh NAME
curl -fsSL https://raw.githubusercontent.com/alooldevs/keyup/main/keyup.sh | bash -s -- github ACCOUNT
```
Pick **2** and add the key it prints at GitHub → Settings → SSH keys. Repeat for each account.
This gives the server the alias `github-ACCOUNT`. For pull-only access to one repo, use `repo OWNER/REPO` instead.

**5. Get the kit and prepare the host** (5 min, then a reboot)
```sh
git clone https://github.com/alooldevs/frappe-stack.git ~/stack
sudo bash ~/stack/bootstrap/host-prep.sh     # Docker, 4G swap, sysctl, SSH keys-only
sudo reboot                                  # if it says REBOOT NEEDED; otherwise log out and in
```

**6. Shared services** (2 min)
```sh
echo 'export PATH=$HOME/stack/bin:$PATH' >> ~/.bashrc && . ~/.bashrc
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
| `bin/stack` | the one command | yes |
| `bootstrap/host-prep.sh` | one-time host setup | yes |
| `base/` | Traefik (upstream minus dashboard), MariaDB tuning | yes |
| `templates/` | what `new-bench` copies | yes |
| `benches/<bench>/` | build.env, apps.json, patched Containerfile, build logs | no |
| `env/` | settings, secrets, generated passwords (mode 600) | no |
| `compose/` | rendered compose files, what's actually running | no |
| `overrides/<name>.yaml` | optional per-server tweak, appended to that stack | no |
| `frappe_docker/` | upstream, checked out at the pinned commit | no |

## Good to know

- **CPU credits.** B-series VMs sustain 40% of their CPU and burst on banked credits. Builds use them up.
  Check *CPU Credits Remaining* in the Azure portal before several builds in a row.
- **Memory** (measured): a bench idles at about 370 MB, MariaDB at about 410 MB, Traefik at about 25 MB.
  CPU runs out before RAM does.
- **Docker ignores ufw.** The Azure network security group (NSG) is the firewall. Only Traefik publishes
  ports.
- **Backups stay on this disk.** They protect against app mistakes, not against losing the VM. Copy them
  off-site yourself.
- **Disk after updates.** The previous bench image stays behind (about 3 GB). List them with
  `docker image ls 'stack/*'` and remove old tags with `docker image rm stack/alpha:<old-tag>`.
  The build cache grows too: check it with `docker buildx du` and trim it with
  `docker buildx prune --keep-storage 10GB`.
- **Moving to a newer frappe_docker:** bump `FRAPPE_DOCKER_REF` in `bin/stack`, then `stack init` and
  `stack build <bench>`. The build stops with a clear message if upstream's Containerfile changed shape.
