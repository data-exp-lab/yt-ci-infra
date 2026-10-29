# yt-ci-infra

Infrastructure for running yt's full answer-test suite on demand on [Jetstream2](https://jetstream-cloud.org/),
against the ~200 GB benchmark dataset collection, without paying for an idle big VM.

Jetstream2 bills by instance state, not CPU use, and shelved instances cost nothing. So: one tiny
always-on **controller** watches the yt repo's Actions queue, and one big **worker** stays shelved
until a job needs it. The worker registers as an ephemeral GitHub runner, takes one job, and exits;
the controller shelves it again after a grace period.

The workflow file and the test-runner script live in the yt repo. This repo only knows how to wake
a machine and hand it a runner config.

```
 GitHub (yt repo)                      Jetstream2 allocation
 PR comment by maintainer              ┌──────────────────────────────────────┐
   │                                   │ private network, outbound NAT        │
   ▼                                   │  ┌──────────────┐   OpenStack API    │
 authorize job (ubuntu-latest)         │  │ controller   │──────────────┐     │
   │ pins SHA, checks permission       │  │ m3.tiny      │              ▼     │
   ▼                                   │  │ always on    │  unshelve / shelve │
 answer-tests job queued               │  │ floating IP  │              │     │
 runs-on: [self-hosted, jetstream]     │  └──────┬───────┘              ▼     │
   │  (controller polls)               │         │ jitconfig   ┌──────────────┐│
   └──────────────────────────────────▶│         └────────────▶│ worker m3.xl ││
   ▲ runner registers, runs one job    │                       │ shelved idle ││
   └───────────────────────────────────────────────────────────│ ephemeral    ││
                                       │                       └──────┬───────┘│
                                       │                       ┌──────▼───────┐│
                                       │                       │ data volumes ││
                                       │                       │ datasets RO  ││
                                       │                       │ answers RO/RW││
                                       │                       └──────────────┘│
                                       └──────────────────────────────────────┘
```

## Layout

| path | runs on | what |
|------|---------|------|
| `controller/` | m3.tiny | Python service: reconcile loop, idle shelver, runner-config endpoint. `uv`-managed. |
| `worker/` | m3.xl | One-time provisioning and the per-boot script that mounts volumes and runs one job. |
| `infra/` | your laptop / the worker | `openstack` CLI script to create everything; volume seeding; security-group rationale. |
| `docs/deploy.md` | | Standing it up from nothing, once per allocation. Ends with the v0 manual checklist. |
| `docs/operations.md` | | Recurring tasks: rotate credentials, rebuild the worker, force a shelve, find logs. |

## Controller in one screen

```
yt-controller status                 # queue depth, runner busy, worker state, what it would do
yt-controller reconcile-once --dry-run
yt-controller run                    # what the systemd service runs: loop + endpoint
yt-controller idle-shelver           # timer-driven backstop, independent of the loop
yt-controller shelve | unshelve      # manual, waits for the transition
```

The decision is a pure function of (queued jobs, runner busy, worker status, idle time); see
`controller/src/yt_controller/reconcile.py` and its tests. Secrets live in `/etc/yt-controller/env`
(template: `controller/env.example`), never in this repo. The worker holds no secrets at all.

## Development

```
cd controller
uv sync
uv run pytest -q
uv run ruff check src tests
```

Nothing here talks to a live cloud except the `openstack.py` and `github.py` clients, which are
exercised by `yt-controller status` once credentials exist.

## License

BSD 3-Clause, see `LICENSE`.
