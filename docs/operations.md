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
| answer stores | `/mnt/yt-answers/answers` on the worker, volume `yt-answers`; reached via the symlink `/mnt/yt-data/answers` because `nose_runner.py` hardcodes `<test_data_dir>/answers` |
| yt-side files | `yt-side/` here; canonical copies in the yt repo |

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

Nothing on the worker changes: it never holds the token, only one-shot just-in-time (JIT)
runner configs.

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

## Change the Python version the suite runs on

Starting point is 3.10 because that is what the last Jenkins run used. The ceiling for the
nose suite is **3.11**: nose 1.3.7's `importer.py` does `from imp import ...`, and `imp` was
removed in Python 3.12. Beyond that means the pytest migration, not a version bump.

Preferred order is pytest first, then 3.11, so the store regeneration below never has to
happen for nose. Whether that holds depends on dev time against yt 4.5.0, which drops 3.10
support: if 4.5.0 lands while the suite is still on nose, the worker has to move to 3.11 to
test `main` at all, and the procedure below is the cost of that.

The version is wired in three places, plus one consequence on the answers volume:

| where | what |
|-------|------|
| `worker/provision.sh` | `uv python install 3.10` puts the interpreter on the worker. Add the new one (keep the old until its stores are retired): `sudo -u runner ~runner/.local/bin/uv python install 3.11` on the live worker, and bump the script for the next rebuild. |
| yt: `tests/run_answer_tests.sh` | `PYTHON_VERSION` default. Drives `uv sync --python` and the path of the nose patch (`.venv/lib/python3.X/site-packages/nose`). Reference copy: `yt-side/run_answer_tests.sh`. |
| yt: `.github/workflows/build-test.yaml` | the nose jobs pin `python-version: '3.10'`. Not required for the worker, but keep them in step so one version of nose is in use. |
| answers volume | `nose_runner.py` prefixes every store with the interpreter version: `py310_local_art_004` becomes `py311_local_art_004`. Nothing carries over. Every group is a missing store under the new prefix. |

That last row is the real cost. The procedure:

1. Pick a trusted ref (a green run on the current version, or the last-known-good commit).
2. Set `ANSWERS_MODE=rw` on the worker (see "Baseline / store runs" above).
3. Dispatch with `ref=<trusted>` and the new `PYTHON_VERSION`. Since the script reads it from
   the environment, the cleanest way is a one-line change to the default in
   `tests/run_answer_tests.sh` on the ref you dispatch from. Every group generates under the
   new prefix; compare pass runs against its own output and should be green.
4. Set `ANSWERS_MODE=ro` back.
5. Dispatch `main` on the new version with answers read-only. Differences here are interpreter or
   dependency effects (a different numpy wheel resolves for 3.11), not code drift. Triage
   before merging the version bump into the yt repo.
6. Merge the bump in yt. The old `py310_*` directories on the volume are dead weight; delete
   them once nobody needs to compare against the old version (or wipe the whole volume with
   `infra/seed-answers-volume.sh format` and regenerate; it never touches the datasets).

Both prefixes can coexist on the volume, so there is no cut-over moment: a PR that bumps the
version just runs against the new stores, and a PR that does not still runs against the old.

## Dataset pre-flight

The answer framework silently skips writing a store if any dataset in the group is missing,
which looks like a store that never appears. So `infra/datasets.json` has to be right before
the first baseline run. It is a list, one entry per file to download from
https://yt-project.org/data/:

```json
{"datafile": "ExodusII_tests.tar.gz", "note": "unpacks to ExodusII"}
{"datafile": "grs-50-cube.fits.gz", "unpack_to": "radio_fits", "note": "bare file on the site"}
```

`datafile` is the file name, fetched from `https://yt-project.org/data/<datafile>` unless
`url` gives a full download URL instead, for files that never reached the server. `unpack_to`
is a directory under the volume root to unpack into, for the few files that are not a tarball
of one top-level directory; omitted, the file unpacks at the root. `note` is free text. `infra/seed-data-volume.sh` extracts
tarballs and gunzips anything else, keeping the compressed copy (one FITS test wants the
`.fits.gz`, another wants the `.fits`). The list is copied to the worker alongside the
seeding script (`deploy.md` step 2) and is the input to both `fetch` and `verify`.

**Keeping it current.** The normal path is incremental. After a run, look for datasets the
suite wanted and did not find; both decorators skip with a reason that names the dataset:

```
grep -hoE "(cannot load dataset|Missing required file) [^ ]+" <run log> | sort -u
```

Find the tarball on the data page, add an entry, re-run `fetch` on the worker (it skips what
is already seeded). Also re-check the "known gaps" list below.

**Rebuilding from scratch** (laptop, how the 2026-11-03 list was made; the first-run skip
check above is the safety net for anything this misses):

1. Names the tests reference: every string literal in `yt/**/test_*.py`, first path
   component. Grep the literals rather than the `requires_ds` / `requires_file` calls; most
   go through a module-level constant. Drop `DD0010`, which ships with yt in `tests/`.
2. The site manifest: `curl -sL https://yt-project.org/data/datafiles.json`. The data page is
   rendered from it. Use each entry's `url`; the `filename` field is a display name and differs
   from the URL basename in a few cases.
3. What each tarball unpacks to, without downloading it: `curl -sL <url> | tar tzf - | head -1`
   reads the first gzip block and drops the connection. About ten tarballs unpack to a name
   other than their stem, two unpack to a bare file.
4. Match step 1 against step 3. Each match is an entry. A test name with no match is inside a
   tarball under another name (step 3 shows it), a bare file on the site (write `unpack_to`),
   or not in the manifest at all. For the last case, search the website repo's pull requests
   for the name: datasets arrive through a companion PR there, and the file often sits on the
   server unlisted, or only as an attachment on the PR (write `url`).
5. `curl -sI` each URL once. The manifest has carried dead links.

The manifest is not the server. `yt upload` (use.yt) has returned 500s for years, so files
reach the server unevenly. The rule for what goes in the list: anything in the manifest, plus
anything a website PR added that never got copied to the server (`url` entries: the two
boxlib files attached to PR 129, `riot_sedov_curvlinear` from the author's share on PR 141,
`quokka` attached to PR 142), plus files that are on the server but were never in the
manifest (`no_fields`, `no_particles`, `singleParticle`, uploaded for yt PR 1645). Not
anything a website PR deliberately removed from the manifest, since the old Jenkins runner
fetched what the manifest listed and removal was a decision.

Known gaps as of 2026-11-03, all tests that skip:

- amrvac. The tests load `amrvac/bw_2d0000.dat` and friends, the layout of the pre-2021
  tarballs (`amrvac_*.tar.gz`, still on the server). Website PR 97 replaced those manifest
  entries with per-run tarballs (`bw_polar_2d.tar.gz` and so on, in the list) that unpack to
  different names and files, and the tests were never updated to match. Deliberately not
  added; the fix is in the yt tests.
- `output_00080_new_halos` (AdaptaHOP, website PR 109): its only copy was on use.yt and is
  gone.

**Verifying the volume (worker).** After seeding, and again before any baseline run:

```
sudo ./seed-data-volume.sh verify datasets.json
```


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

## Runner lifecycle on the worker

`yt-runner.service` fetches a single-use config, takes one job, exits, and restarts itself to
fetch the next. So an ACTIVE worker normally has one idle runner registered and waiting; that
is not a fault. The controller shelves the instance once nothing has been queued or busy for
`GRACE_SECONDS`, which kills the idle runner; GitHub drops the dead registration on its own.
Small race: a job dispatched in the seconds between the shelve decision and the kill fails
and must be re-run. Acceptable for v1.

If the config fetch fails (controller down, security group wrong), the service exits non-zero
and stays down until the next unshelve. `journalctl -u yt-runner` on the worker says why.

## Known gotchas

- The controller's floating IP is stable as long as the controller is never shelved: Jetstream2
  reclaims floating IPs from instances shelved more than 45 days. Safe to hard-code in your SSH
  config. If SSH ever stops resolving, check in Horizon (Network → Floating IPs) that the
  address is still associated. Background in `infra/networking.md`.
- Unshelve takes 1–3 min; polling adds up to `POLL_SECONDS`. A queued job sits for a few minutes
  before the runner appears. That is expected.
- JIT configs expire in about an hour and are single-use. If the worker boots but the runner
  never appears, check `journalctl -u yt-runner` on the worker and `journalctl -u yt-controller`
  for `generate-jitconfig failed` (usually a token permission problem).
- Usage reporting to ACCESS (the NSF program that allocates Jetstream2 time) lags 12–24 h;
  `openstack` status is the source of truth for whether the worker is burning service units
  (SUs) right now.
