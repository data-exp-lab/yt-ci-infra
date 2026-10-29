# Deploy: standing it up from nothing

Done once per allocation. Afterwards, see `operations.md`.

Development happens against the fork `chavlin/yt`; runners register per repository, so
`yt-project/yt` sees nothing until the cut-over step at the end.

## 0. Prerequisites on your laptop

- `uv` and `gh`.
- `python-openstackclient` (`uv tool install python-openstackclient`).
- An OpenStack **application credential** for the allocation, downloaded from Horizon into
  `~/.config/openstack/clouds.yaml` as a cloud named `jetstream`. Never commit this file.
- An SSH keypair (`~/.ssh/id_ed25519.pub`).

## 1. Create the cloud resources

```
export OS_CLOUD=jetstream ADMIN_CIDR=<your ip>/32
# TODO: confirm IMAGE and PUBLIC_NET names in Horizon first
./infra/create.sh
```

Creates `yt-net`, the two security groups (`infra/security-groups.md`), two volumes, the
controller (floating IP) and the worker (no floating IP, both volumes attached). Note the
controller's floating and private IPs from the output.

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
`yt-runner.service` unit. Then shelve it:

```
openstack server shelve yt-worker
```

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

In the fork: enable Actions (disabled on forks by default), and add
`.github/workflows/answer-tests.yml` plus `run_answer_tests.sh` as drafted in the planning note.
The workflow targets `runs-on: [self-hosted, jetstream]`; the label must match `RUNNER_LABEL`.

## 6. v0 checklist: manual dispatch, no controller loop

Validates the worker image, volume mounts, JIT handoff, ephemeral runner, the suite, and status
reporting, with the controller only serving configs. Leave `yt-controller.service` stopped and run
`yt-controller serve` in a tmux instead, so nothing shelves the worker under you.

1. `openstack server unshelve yt-worker` (or `yt-controller unshelve`), wait for ACTIVE.
2. On the controller, watch `journalctl -u yt-controller` (or the `serve` output) for
   `issued runner config`.
3. `gh api repos/chavlin/yt/actions/runners` shows one runner labelled `jetstream`, `online`.
4. Actions tab on the fork: run `answer-tests` via `workflow_dispatch`. Optional `pr` input pins
   a PR head SHA.
5. The runner goes `busy`; the job log streams; on completion the runner deregisters and
   `yt-runner.service` exits on the worker.
6. Check the commit status `answer-tests` on the SHA, and the xunit artifacts on the run.
7. `openstack server shelve yt-worker`.

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
