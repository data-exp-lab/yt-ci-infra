# Operations: recurring tasks

For first-time setup see `deploy.md`.

## Where things are

| what | where |
|------|-------|
| controller code | `/opt/yt-controller` (symlink into the `/opt/yt-ci-infra` checkout) |
| controller secrets | `/etc/yt-controller/env`, `~yt-controller/.config/openstack/clouds.yaml` |
| controller state | `/var/lib/yt-controller/state.json` (last-activity timestamp; safe to delete) |
| controller logs | `journalctl -u yt-controller`, `journalctl -u yt-controller-idle-shelver` |
| worker runner | `/opt/yt-runner`, job workspaces under `_work/`, diagnostics under `_diag/` |
| worker config | `/etc/yt-runner/env` (`CONTROLLER_URL`, `ANSWERS_MODE`) |
| worker logs | `journalctl -u yt-runner` |
| datasets | `/mnt/yt-data` on the worker, volume `yt-data`, always read-only |
| answer stores | `/mnt/yt-answers/answers` on the worker, volume `yt-answers` |

## Is it healthy?

```
yt-controller status
openstack server show yt-worker -c status -c updated_at
gh api repos/$GITHUB_REPO/actions/runners --jq '.runners[] | {name, status, busy}'
```

Shelved worker + no queued jobs + no runners is the normal resting state.

## Force a shelve / unshelve

```
yt-controller shelve      # waits for SHELVED_OFFLOADED
yt-controller unshelve    # waits for ACTIVE; the worker boots and fetches a runner config
```

Or `openstack server shelve|unshelve yt-worker`. Never `stop` or `suspend`: those bill at 50% and
75% respectively. Shelved bills zero.

If the controller is misbehaving, `systemctl stop yt-controller` first so it does not fight you.
The idle shelver timer keeps running and will shelve an idle worker after `IDLE_SHELVE_SECONDS`;
stop `yt-controller-idle-shelver.timer` too if you need the worker up for interactive work.

## Rotate the GitHub token

1. Mint the new token (same permissions: Administration r/w, Actions read, scoped to the repo).
2. Edit `GITHUB_TOKEN` in `/etc/yt-controller/env`.
3. `systemctl restart yt-controller`; check `yt-controller status` works.
4. Revoke the old token on GitHub.

Nothing on the worker changes: it never holds the token, only one-shot JIT configs.

## Rotate the OpenStack application credential

1. Horizon → Identity → Application Credentials → create a new one, download `clouds.yaml`.
2. Replace `~yt-controller/.config/openstack/clouds.yaml` (mode 600, owned by `yt-controller`).
3. `systemctl restart yt-controller`; `yt-controller status` must show the worker.
4. Delete the old credential in Horizon.

## Baseline / store runs: answers volume read-write

PR compare runs mount `/mnt/yt-answers` read-only so untrusted code can never write a baseline;
a missing store then fails loudly rather than being generated. To generate a baseline from a
trusted ref:

1. On the worker (unshelve it, SSH via ProxyJump): set `ANSWERS_MODE=rw` in `/etc/yt-runner/env`.
2. Dispatch the workflow with the trusted ref.
3. Set `ANSWERS_MODE=ro` back **before** the next PR run. This is a manual guard for v1; TODO:
   drive the mode from the job (the controller could pass it with the runner config).

Shelve files are dbm-backend dependent: generate stores on the worker, never copy from a laptop.

## Dataset pre-flight

The answer framework silently skips writing a store if any dataset in the group is missing,
which looks like a store that never appears. Before a baseline run, verify the volume holds
every dataset the tests reference:

```
# in a yt checkout: every dataset name the test suite asks for
grep -rhoE '(requires_ds|data_dir_load|can_run_ds)\("[^"]+"' yt/ | sed -E 's/.*\("//; s/"$//' | cut -d/ -f1 | sort -u > datasets.txt
sudo ./seed-volume.sh verify datasets.txt     # on the worker
```

TODO: turn this into a script in `infra/` once the list is stable.

## Rebuild the worker from clean

Reasons: a job left the root disk in a bad state, a runner-version bump, or periodic hygiene
(the worker runs maintainer-approved but still third-party code with network access).

```
openstack server unshelve yt-worker         # if shelved
openstack server remove volume yt-worker yt-data
openstack server remove volume yt-worker yt-answers
openstack server delete yt-worker
IMAGE=... ./infra/create.sh                  # recreates only the missing worker, re-attaches volumes
# then worker/provision.sh as in deploy.md step 3, and shelve
```

The volumes are untouched by this. Alternative with less downtime: snapshot the provisioned
worker once (`openstack server image create yt-worker --name yt-worker-golden`) and rebuild from
that image instead of re-provisioning. TODO: decide after the first rebuild whether the snapshot
is worth maintaining.

## Update the controller code

```
cd /opt/yt-ci-infra && sudo git pull
cd controller && sudo -u yt-controller ~yt-controller/.local/bin/uv sync --no-dev
sudo systemctl restart yt-controller
```

If a systemd unit changed: copy it to `/etc/systemd/system/` and `systemctl daemon-reload` first.

## Known gotchas

- Unshelve takes 1–3 min; polling adds up to `POLL_SECONDS`. A queued job sits for a few minutes
  before the runner appears. That is expected.
- JIT configs expire in about an hour and are single-use. If the worker boots but the runner
  never appears, check `journalctl -u yt-runner` on the worker and `journalctl -u yt-controller`
  for `generate-jitconfig failed` (usually a token permission problem).
- Usage reporting to ACCESS lags 12–24 h; `openstack` status is the source of truth for whether
  the worker is burning SUs right now.
