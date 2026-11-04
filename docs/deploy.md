# Deploy: standing it up from nothing

Done once per allocation. Afterwards, see `operations.md`.

Development happens against the fork `chrishavlin/yt`; runners register per repository, so
`yt-project/yt` sees nothing until the cut-over step at the end.

## 0. Prerequisites on your laptop

- `uv` and `gh`.
- An SSH keypair (`~/.ssh/id_ed25519.pub`).
- An OpenStack **application credential** for the allocation. In Horizon
  (https://js2.jetstream-cloud.org, pick the allocation top-left): Identity → Application
  Credentials → Create. Name it `yt-controller`, leave roles and access rules at their defaults,
  do not tick "unrestricted". On the confirmation screen download `clouds.yaml`; the secret is
  shown once. Save it as `~/.config/openstack/clouds.yaml`, open the file, and rename the
  `openstack` key under `clouds:` to `jetstream` (that is the name `OS_CLOUD=jetstream` looks
  up). Never commit this file. (Horizon's own openrc generator is broken on Jetstream2; use the
  application-credential download.)
- Only if you take the script route in step 1: `python-openstackclient`
  (`uv tool install python-openstackclient`).

## 1. Create the cloud resources

Two equivalent routes. The result either way: a private network with a router to `public`,
two security groups, two volumes, a tiny always-on controller with the only floating IP, and a
big worker with no floating IP and both volumes attached. Nothing downstream cares which route
you took; the controller finds the worker by name (`WORKER_NAME`).

Use **Horizon**, not Exosphere, for creating the instances. Exosphere does not let you choose
security groups (its instances get a wide-open group) and it injects its own cloud-init
(Guacamole, an `exouser` account). Exosphere is fine afterwards for shelve/unshelve buttons and
for seeing volume attachments.

### 1A. Horizon, click-through

1. **Key pair.** Compute → Key Pairs → Import Public Key. Name `yt-key` (the default
   `infra/create.sh` looks for), Key Type `SSH Key`, and paste `~/.ssh/id_ed25519.pub`
   (`pbcopy < ~/.ssh/id_ed25519.pub` puts it on the clipboard).
2. **Network.** If anything was ever launched in this allocation through Exosphere, Network →
   Networks shows an `auto_allocated_network` with `auto_allocated_subnet_v4`. Check Network →
   Routers for `auto_allocated_router` with external gateway `public` and an interface on
   that subnet. If both exist, skip to step 3 and pick `auto_allocated_network` wherever
   steps 5 and 6 say `yt-net`. If only the router is missing, create it as below but attach
   `auto_allocated_subnet_v4`. Otherwise: Network → Networks → Create Network, name
   `yt-net`, subnet `yt-subnet` with range `10.0.42.0/24` and DNS `8.8.8.8`. Then Network →
   Routers → Create Router `yt-router` with external network `public`, and on its
   Interfaces tab add `yt-subnet`.
3. **Security groups.** Network → Security Groups. Both start with all egress and no ingress.
   Field-by-field rules are in `infra/networking.md`, which also defines the terms (CIDR,
   ingress, remote group).
   - Create `yt-worker-sg`. Add Rule: SSH, Ingress, Remote = **Security Group** →
     `yt-controller-sg`, Ether Type IPv4. Nothing else; leave the 2 egress entries alone.
   - Create `yt-controller-sg`. Add Rule: SSH, Ingress, Remote = CIDR, `<your ip>/32`.
     Add Rule: Custom TCP Rule, Ingress, port `8080`, Remote = **Security Group** →
     `yt-worker-sg`, Ether Type left at IPv4.
   - Leave the `default` group untouched (Jetstream2's own advice).
4. **Volumes.** Volumes → Volumes → Create Volume. `yt-data`, 200 GiB, source "No source,
   empty volume". Again for `yt-answers`, 50 GiB. Not bootable.
5. **Controller.** Compute → Instances → Launch Instance.
   - Details: name `yt-controller`.
   - Source: Boot Source = Image, Create New Volume = **No**, filter on `Featured`, pick the
     Ubuntu 24 image.
   - Flavor: `m3.tiny`.
   - Networks: `yt-net` (or the auto-allocated one).
   - Security Groups: `yt-controller-sg` only. **Remove `default`** if it is pre-selected.
   - Key Pair: yours. Launch.
   - Once Active: Actions → Associate Floating IP → `+` to allocate one from `public` →
     Associate. Note the floating IP and the private `10.x` address shown in the IP column.
     This is the only public address in the system; `infra/networking.md` explains why.
6. **Worker.** Launch Instance again: name `yt-worker`, same image, flavor `m3.xl`, same
   network, security group `yt-worker-sg` only (remove `default`), same key pair.
   **Do not associate a floating IP.** Note its private address.
7. **Attach volumes.** Volumes → Volumes → Actions on `yt-data` → Manage Attachments → select
   `yt-worker` → Attach. Same for `yt-answers`. On the worker they show up as `/dev/sd*`
   devices, and which letter each volume gets depends on attach order, so identify them by
   size in step 2 rather than trusting the names here.

### 1B. Script

Does exactly the list above with the `openstack` CLI, skipping anything that already exists by
name. Read it first; it is 80 lines.

```
export OS_CLOUD=jetstream ADMIN_CIDR=<your ip>/32
# TODO: confirm IMAGE and PUBLIC_NET names in Horizon first (Compute → Images; Network → Networks)
./infra/create.sh
```

It prints the controller's floating and private IPs at the end. The same script is what
`operations.md` uses to rebuild just the worker later, since it only creates what is missing.

### 1C. Record the addresses and write the SSH config (either route)

You now have three addresses: the controller's floating IP and private `10.x` address, and
the worker's private address. Keep them somewhere outside this repo. Each is used later:

- Controller floating IP: the `HostName` below. The only public address in the system.
- Controller private IP: `CONTROLLER_URL` in step 3 and `TOKEN_BIND` in step 4, the
  worker-to-controller handoff over the private network.
- Worker private IP: the `HostName` below, reached through the controller as a jump host.

Add to `~/.ssh/config`; the rest of this document assumes `ssh yt-controller` and
`ssh yt-worker` work:

```
Host yt-controller
    HostName <controller floating ip>
    User ubuntu
Host yt-worker
    HostName <worker private ip>
    User ubuntu
    ProxyJump yt-controller
```

Test with `ssh yt-controller`. A timeout usually means your public IP is no longer the one in
`yt-controller-sg`; add a second SSH rule for the current IP rather than editing the first.

## 2. Seed the volumes (on the worker)

`infra/datasets.json` lists what to fetch; how it was made and how to keep it current is in
`operations.md`, "Dataset pre-flight". Fetching 38 GB of tarballs takes a while; the script
reports failures at the end and can be re-run to pick up only what is missing.

The worker gets its own checkout of this repo, at the same path as on the controller. It has no
floating IP but outbound access works, and the repo is public, so a plain HTTPS clone needs no
credentials. Owned by the login user so `git pull` works without sudo.

```
ssh yt-worker
sudo git clone https://github.com/data-exp-lab/yt-ci-infra /opt/yt-ci-infra
sudo chown -R "$USER": /opt/yt-ci-infra
cd /opt/yt-ci-infra
sudo lsblk                                                    # 200G is yt-data, 50G is yt-answers
sudo DATA_DEV=/dev/sdc ./infra/seed-data-volume.sh format     # the 200G device
sudo ./infra/seed-data-volume.sh fetch infra/datasets.json
sudo ./infra/seed-data-volume.sh verify infra/datasets.json
sudo ANSWERS_DEV=/dev/sdb ./infra/seed-answers-volume.sh format  # the 50G device
```

The answers script only formats the volume and leaves an empty `answers/` directory, root-owned
until `provision.sh` (section 3) creates the runner user and chowns it. The stores themselves
come from the first baseline run of the suite (`operations.md`, "Baseline / store runs"); they
cannot be seeded from outside the worker.

Budget: the dataset pull is the slow part; do it before provisioning so a provisioning mistake
does not cost a re-download. The volumes persist independently of the worker.

## 3. Provision the worker (on the worker)

```
ssh yt-worker
cd /opt/yt-ci-infra && git pull
sudo CONTROLLER_URL=http://<controller private ip>:8080 ./worker/provision.sh
```

Installs the Actions runner, `uv`, Python 3.10, mount points, `/etc/yt-runner/env`, and the
`yt-runner.service` unit, and chowns the answers volume to the runner user. The apt output
includes harmless noise: `Ign` lines for the image's local `/software/pkgrep` repo, and a run of
`Unable to locate package libssl1.1` / `libicuNN` from the runner's `installdependencies.sh`
probing for older library versions before settling on the ones noble has. The script is safe to
re-run if it stops partway. On a re-run after the unit is enabled, `yt-runner.service` has already
mounted the volumes at boot; the script remounts the answers volume read-write for its chown.
Then shelve it: Horizon → Compute → Instances → Actions → Shelve
Instance (or the Shelve button in Exosphere), or

```
openstack server shelve yt-worker
```

Jetstream2 confirms shelved instances are not charged service units (SUs, the allocation's
billing unit), and that shelve and unshelve each
take a few minutes. The volumes stay attached across shelve; watch the first unshelve to
confirm they come back mounted.

## 4. Install the controller (on the controller)

```
ssh yt-controller
sudo useradd --system --create-home yt-controller
sudo git clone https://github.com/data-exp-lab/yt-ci-infra /opt/yt-ci-infra
sudo chown -R yt-controller: /opt/yt-ci-infra
sudo ln -s /opt/yt-ci-infra/controller /opt/yt-controller
sudo -u yt-controller bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
cd /opt/yt-controller && sudo -u yt-controller ~yt-controller/.local/bin/uv sync --no-dev
```

Secrets. First, from your laptop, copy the application credential over (it lands as
`~/clouds.yaml` on the controller):

```
scp ~/.config/openstack/clouds.yaml yt-controller:
```

Then on the controller:

```
sudo mkdir -p /etc/yt-controller
sudo cp /opt/yt-controller/env.example /etc/yt-controller/env
sudo chmod 600 /etc/yt-controller/env
sudo $EDITOR /etc/yt-controller/env          # GITHUB_REPO, GITHUB_TOKEN, TOKEN_BIND=<private ip>
sudo -u yt-controller mkdir -p ~yt-controller/.config/openstack
sudo cp ~/clouds.yaml ~yt-controller/.config/openstack/clouds.yaml   # application credential
sudo chown -R yt-controller: ~yt-controller/.config; sudo chmod 600 ~yt-controller/.config/openstack/clouds.yaml
```

GitHub credential for the fork phase: a fine-grained personal access token (PAT: a
password-like string GitHub issues to your account for API use; "fine-grained" means it is
limited to named repositories and permissions). Create it at GitHub → Settings → Developer
settings → Personal access tokens → Fine-grained tokens. Resource owner `chrishavlin`, repository
access `chrishavlin/yt` only, permissions **Administration read/write** and **Actions read**.
Minting just-in-time (JIT) runner configs, the single-use registrations the controller hands
the worker at boot, is what needs Administration.

Smoke test before enabling anything. Actions must already be enabled on the fork (it is
disabled on forks by default; button on the fork's Actions tab), otherwise every
`/actions/...` endpoint returns 404 and `status` crashes:

```
cd /opt/yt-controller
sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller status
```

Expect `worker: yt-worker SHELVED_OFFLOADED`, `queued: 0`, `would: none`.

Install the units. If you are about to run the v0 checklist (section 6), stop after
`daemon-reload`: both the reconciler and the idle shelver will shelve the worker under you.
Enable them at the start of v1.

```
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yt-controller.service yt-controller-idle-shelver.timer   # v1
journalctl -u yt-controller -f
```

## 5. The yt side

Three files go into the yt repo (the fork during v0/v1): one new workflow and two edited test
helpers. Reference copies, with an explanation of what changed and why, are in `yt-side/`:

| copy here | destination in yt |
|-----------|-------------------|
| `yt-side/answer-tests.yml` | `.github/workflows/answer-tests.yml` (new) |
| `yt-side/nose_runner.py` | `tests/nose_runner.py` (replace) |
| `yt-side/ci_install.sh` | `tests/ci_install.sh` (replace) |

Then enable Actions on the fork (disabled on forks by default; button on its Actions tab).
`workflow_dispatch` runs from whichever branch you pick in the dropdown, so the files can sit
on a feature branch for v0. The `/run-answer-tests` comment path reads the workflow from the
default branch, so merge them there before testing v1.

The workflow's `runs-on: [self-hosted, jetstream]` label must match `RUNNER_LABEL`.

## 6. v0 checklist: manual dispatch, no controller loop

Validates the worker image, volume mounts, JIT handoff, ephemeral runner, the suite, and status
reporting, with the controller only serving configs. Leave `yt-controller.service` stopped and run
`yt-controller serve` in a tmux instead, so nothing shelves the worker under you.

0. No answer stores exist yet, so the first run of every group is a store run and needs the
   answers volume writable: set `ANSWERS_MODE=rw` in `/etc/yt-runner/env` on the worker
   (`operations.md`, "Baseline / store runs"). Set it back to `ro` before the first PR run.
1. On the controller, start the config endpoint in a tmux session so it outlives your ssh login:

   ```
   tmux new -s serve
   cd /opt/yt-controller && sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller serve
   ```

   As the service user, since that is whose `~/.config/openstack/clouds.yaml` the SDK reads
   (as `ubuntu` it fails with `Cloud jetstream was not found`). Detach with `Ctrl-b` then `d`;
   reattach with `tmux attach -t serve`.
2. Get the worker's runner service running. One of:
   - Worker shelved: unshelve it (Horizon Actions → Unshelve, Exosphere,
     `openstack server unshelve yt-worker`, or `yt-controller unshelve`) and wait for ACTIVE.
     `yt-runner.service` starts at boot and registers on its own.
   - Worker already up (right after provisioning, say): the service tried at boot, found nothing
     serving, and stays down. Start it by hand on the worker:
     `sudo systemctl start yt-runner.service && journalctl -u yt-runner -f`.
3. Confirm the handoff. The serve window on the controller (reattach with `tmux attach -t serve`)
   logs `issued runner config`; the worker journal shows the mount line and
   `registering as ...; taking one job`. From the laptop,
   `gh api repos/chrishavlin/yt/actions/runners` then lists one runner labelled `jetstream`,
   `online`. It lists nothing until the service has registered.
4. Dispatch. Actions tab on the fork, workflow `answer-tests`, branch dropdown set to the
   branch carrying the workflow, `groups` input naming one small group (e.g. `local_art_004`)
   so the first round trip takes minutes, not an hour. `pr` or `ref` pins what to check out.
   CLI equivalent: `gh workflow run answer-tests --repo chrishavlin/yt --ref <branch> -f groups=local_art_004`,
   then `gh run watch --repo chrishavlin/yt`.
5. The runner goes `busy`; the job log streams; on completion the runner deregisters and
   `yt-runner.service` restarts on the worker, fetching a fresh config and waiting for the
   next job.
6. Check the commit status `answer-tests` on the SHA, and the xunit artifacts on the run.
7. Shelve the worker again (UI or `openstack server shelve yt-worker`).

Once that works end to end, start `yt-controller.service` and repeat from step 4 only: the loop
should unshelve on the queued job and shelve after `GRACE_SECONDS`. That is v1.

## 7. Cut-over to `yt-project/yt`

- New fine-grained PAT (or GitHub App) with resource owner `yt-project`, repository `yt` only,
  same permissions. Org fine-grained PATs may need admin approval; a GitHub App avoids that.
- Edit `/etc/yt-controller/env`: `GITHUB_REPO=yt-project/yt`, new token. `systemctl restart yt-controller`.
- Open the workflow PR to yt-project/yt. The `issue_comment` trigger reads the workflow from
  `main`, so `/run-answer-tests` only works after merge; `workflow_dispatch` works immediately
  from the PR branch.
- Nothing to deregister on the fork: ephemeral runners clean up after themselves.
