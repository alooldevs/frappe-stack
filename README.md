# frappe-stack

Several Frappe benches on one server, set up the same way every time. You pick one of two engines per
server; both use the same steps up to host prep, and the same verbs afterwards (`init`, `new-bench`,
`site`, `bench`, `backup`, `ps`, `restart`).

| | **Docker** → [DOCKER.md](DOCKER.md) (`bin/stack`) | **Native** → [NATIVE.md](NATIVE.md) (`bin/native`) |
|---|---|---|
| How a bench runs | its own image, apps baked in | a bench folder in `/srv/benches`, like on your Mac |
| Changing app code | `stack build` (≈5 min) + `stack up` + migrate | `bench get-app` / `bench update` directly |
| Isolation | each bench has its own Python, Node, Redis, nginx | benches share the host's nginx, supervisor, MariaDB |
| Rollback | previous image tag | git + backups |
| Disk per bench | ≈3 GB image + build cache | ≈1–2 GB |
| HTTPS | Traefik, automatic | certbot, automatic renewal |
| Frappe's view | officially recommended | supported, "not recommended on bare metal" |

One mode per server: both need ports 80 and 443. Host prep records the mode and refuses the other.

## Have these ready

- A domain for the first site, e.g. `erp.example.org`, and access to its DNS
- An email for Let's Encrypt
- The GitHub account(s) holding any private repos: your Frappe fork, your apps
- Which Frappe (repo and branch) and which apps (repo and branch) the first bench gets

## Fresh server → ready host (about 25 min)

**1. Create the VM** (Azure portal, 10 min)
- Image **Ubuntu Server 24.04 LTS x64**. Size **Standard_B2as_v2** (2 vCPU, 8 GiB) or larger.
- Authentication: **Password**, temporary. Step 3 replaces it with a key and turns password login off.
- Disks: OS disk **64 GiB**, Premium SSD. The 30 GiB default is too small for Docker images and build cache.
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
This gives the server the alias `github-ACCOUNT`; use it in repo URLs: `git@github-ACCOUNT:OWNER/REPO.git`.
For pull-only access to one repo, use `repo OWNER/REPO` instead.

**5. Get the kit and prepare the host** (5–10 min, then a reboot)
```sh
git clone https://github.com/alooldevs/frappe-stack.git ~/stack
sudo bash ~/stack/bootstrap/host-prep.sh docker    # or: native
sudo reboot                                         # if it says REBOOT NEEDED; otherwise log out and in
echo 'export PATH=$HOME/stack/bin:$PATH' >> ~/.bashrc
```
Both modes: system updates, 4G swap, sysctl, SSH keys-only. Docker adds Docker Engine. Native adds
MariaDB 11.8, Node 24, Python 3.14 via uv, frappe-bench, nginx, supervisor, certbot and wkhtmltopdf.
Every package comes from a signed apt repo or a checksum-pinned download.

**Then continue in [DOCKER.md](DOCKER.md) or [NATIVE.md](NATIVE.md), step 6.**

## Updating the kit on a server

```sh
cd ~/stack && git pull
```
Your settings, secrets and benches aren't in git (`.gitignore`), so a pull only changes the kit itself.
