# Deploy: standing it up from nothing

Done once per allocation. Afterwards, see `operations.md`.

Development happens against the fork `chavlin/yt`; runners register per repository, so
`yt-project/yt` sees nothing until the cut-over step at the end.

## 0. Prerequisites on your laptop

- `uv` and `gh`.
- An SSH keypair (`~/.ssh/id_ed25519.pub`).
- An OpenStack **application credential** for the allocation. In Horizon
  (https://js2.jetstream-cloud.org, pick the allocation top-left): Identity → Application
  Credentials → Create. Name it `yt-controller`, leave roles and access rules at their defaults,
  do not tick "unrestricted". On the confirmation screen download `clouds.yaml`; the secret is
  shown once. Save it as `~/.config/openstack/clouds.yaml` with the cloud named `jetstream`.
  Never commit this file. (Horizon's own openrc generator is broken on Jetstream2; use the
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

1. **Key pair.** Compute → Key Pairs → Import Public Key. Paste `~/.ssh/id_ed25519.pub`.
2. **Network.** If anything was ever launched in this allocation through Exosphere, an
   `auto_allocated_network` with a router already exists; reuse it. Otherwise: Network →
   Networks → Create Network, name `yt-net`, subnet `yt-subnet` with range `10.0.42.0/24` and
   DNS `8.8.8.8`. Then Network → Routers → Create Router `yt-router` with external network
   `public`, and on its Interfaces tab add `yt-subnet`.
3. **Security groups.** Network → Security Groups. Both start with all egress and no ingress.
   Field-by-field rules are in `infra/security-groups.md`.
   - Create `yt-worker-sg`. Add no rules.
   - Create `yt-controller-sg`. Add Rule: SSH, Ingress, Remote = CIDR, `<your ip>/32`.
     Add Rule: Custom TCP Rule, Ingress, port `8080`, Remote = **Security Group** →
     `yt-worker-sg`.
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
6. **Worker.** Launch Instance again: name `yt-worker`, same image, flavor `m3.xl`, same
   network, security group `yt-worker-sg` only (remove `default`), same key pair.
   **Do not associate a floating IP.** Note its private address.
7. **Attach volumes.** Volumes → Volumes → Actions on `yt-data` → Manage Attachments → select
   `yt-worker` → Attach. Same for `yt-answers`. Horizon shows the device each landed on
   (typically `/dev/vdb` and `/dev/vdc`); you need these for step 2.

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

SSH config for the rest of this document:

```
Host yt-controller
    HostName <controller floating ip>
    User ubuntu
Host yt-worker
    HostName <worker private ip>
    User ubuntu
    ProxyJump yt-controller
```

## 2. Seed the volumes (on the worker)

```
scp infra/seed-volume.sh yt-worker:
ssh yt-worker
sudo lsblk                                # identify the 200G and 50G devices
sudo DATA_DEV=/dev/vdb ANSWERS_DEV=/dev/vdc ./seed-volume.sh format
sudo ./seed-volume.sh fetch datasets.txt  # TODO: datasets.txt, see operations.md "dataset pre-flight"
sudo ./seed-volume.sh verify datasets.txt
```

Budget: the dataset pull is the slow part; do it before provisioning so a provisioning mistake
does not cost a re-download. The volumes persist independently of the worker.

## 3. Provision the worker (on the worker)

```
scp -r worker yt-worker:
ssh yt-worker
sudo CONTROLLER_URL=http://<controller private ip>:8080 ./worker/provision.sh
```

Installs the Actions runner, `uv`, Python 3.10, mount points, `/etc/yt-runner/env`, and the
`yt-runner.service` unit. Then shelve it: Horizon → Compute → Instances → Actions → Shelve
Instance (or the Shelve button in Exosphere), or

```
openstack server shelve yt-worker
```

Jetstream2 confirms shelved instances are not charged SUs, and that shelve and unshelve each
take a few minutes. The volumes stay attached across shelve; watch the first unshelve to
confirm they come back mounted.

## 4. Install the controller (on the controller)

```
ssh yt-controller
sudo apt-get install -y git
sudo useradd --system --create-home yt-controller
sudo git clone https://github.com/yt-project/yt-ci-infra /opt/yt-ci-infra
sudo ln -s /opt/yt-ci-infra/controller /opt/yt-controller
sudo -u yt-controller bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
cd /opt/yt-controller && sudo -u yt-controller ~yt-controller/.local/bin/uv sync --no-dev
```

Secrets:

```
sudo mkdir -p /etc/yt-controller
sudo cp /opt/yt-controller/env.example /etc/yt-controller/env
sudo chmod 600 /etc/yt-controller/env
sudo $EDITOR /etc/yt-controller/env          # GITHUB_REPO, GITHUB_TOKEN, TOKEN_BIND=<private ip>
sudo -u yt-controller mkdir -p ~yt-controller/.config/openstack
sudo cp ~/clouds.yaml ~yt-controller/.config/openstack/clouds.yaml   # application credential
sudo chown -R yt-controller: ~yt-controller/.config; sudo chmod 600 ~yt-controller/.config/openstack/clouds.yaml
```

GitHub credential for the fork phase: fine-grained PAT, resource owner `chavlin`, repository
access `chavlin/yt` only, permissions **Administration read/write** and **Actions read**.
Minting JIT runner configs is what needs Administration.

Smoke test before enabling anything:

```
cd /opt/yt-controller
sudo -u yt-controller env $(sudo cat /etc/yt-controller/env | xargs) .venv/bin/yt-controller status
```

Expect `worker: yt-worker SHELVED_OFFLOADED`, `queued: 0`, `would: none`.

Enable the units:

```
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yt-controller.service yt-controller-idle-shelver.timer
journalctl -u yt-controller -f
```

## 5. The yt side

Two files go into the yt repo (the fork during v0/v1). Reference copies, with an explanation
of what they do, are in `yt-side/`:

| copy here | destination in yt |
|-----------|-------------------|
| `yt-side/answer-tests.yml` | `.github/workflows/answer-tests.yml` |
| `yt-side/run_answer_tests.sh` | `tests/run_answer_tests.sh` |

Then enable Actions on the fork (disabled on forks by default; button on its Actions tab).
`workflow_dispatch` runs from whichever branch you pick in the dropdown, so the files can sit
on a feature branch for v0. The `/run-answer-tests` comment path reads the workflow from the
default branch, so merge them there before testing v1.

The workflow's `runs-on: [self-hosted, jetstream]` label must match `RUNNER_LABEL`.

## 6. v0 checklist: manual dispatch, no controller loop

Validates the worker image, volume mounts, JIT handoff, ephemeral runner, the suite, and status
reporting, with the controller only serving configs. Leave `yt-controller.service` stopped and run
`yt-controller serve` in a tmux instead, so nothing shelves the worker under you.

1. Unshelve the worker: Horizon Actions → Unshelve, Exosphere, `openstack server unshelve yt-worker`,
   or `yt-controller unshelve`. Wait for ACTIVE.
2. On the controller, watch `journalctl -u yt-controller` (or the `serve` output) for
   `issued runner config`.
3. `gh api repos/chavlin/yt/actions/runners` shows one runner labelled `jetstream`, `online`.
4. Actions tab on the fork: run `answer-tests` via `workflow_dispatch`. Start with a `groups`
   input naming one small group (e.g. `local_art_004`) so the first round trip takes minutes,
   not an hour. `pr` or `ref` pins what to check out.
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
