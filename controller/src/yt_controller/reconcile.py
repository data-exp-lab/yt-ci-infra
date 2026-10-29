"""Desired-state reconciliation: GitHub queue in, one OpenStack action out.

`decide` is pure so every state combination is unit-testable and `reconcile-once --dry-run`
can be run from a laptop against the live APIs without touching the worker.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from enum import Enum

from .config import Settings
from .github import GitHub
from .openstack import OpenStack
from .state import State

log = logging.getLogger(__name__)

SHELVED_STATES = {"SHELVED", "SHELVED_OFFLOADED"}
TRANSITIONAL_STATES = {"SHELVING", "UNSHELVING", "BUILD", "REBOOT", "HARD_REBOOT"}


class Action(Enum):
    NONE = "none"
    UNSHELVE = "unshelve"
    SHELVE = "shelve"


@dataclass(frozen=True)
class Observation:
    queued_jobs: int
    runner_busy: bool
    worker_status: str
    idle_seconds: float | None  # since last queued/busy/wake; None when never recorded

    @property
    def wanted(self) -> bool:
        return self.queued_jobs > 0 or self.runner_busy


def decide(obs: Observation, grace_seconds: float) -> Action:
    status = obs.worker_status.upper()
    if obs.wanted and status in SHELVED_STATES:
        return Action.UNSHELVE
    if (
        not obs.wanted
        and status == "ACTIVE"
        and obs.idle_seconds is not None
        and obs.idle_seconds > grace_seconds
    ):
        return Action.SHELVE
    return Action.NONE


def observe(
    gh: GitHub, os_: OpenStack, state: State, label: str, now: float | None = None
) -> Observation:
    now = time.time() if now is None else now
    queued = gh.queued_jobs(label)
    busy = gh.runner_busy(label)
    status = os_.status()
    if queued or busy:
        state.touch(now)
    last = state.last_activity()
    idle = None if last is None else now - last
    return Observation(
        queued_jobs=queued, runner_busy=busy, worker_status=status, idle_seconds=idle
    )


def apply(action: Action, os_: OpenStack, state: State, dry_run: bool) -> None:
    if action is Action.NONE:
        return
    if dry_run:
        log.info("dry-run: would %s %s", action.value, os_.worker_name)
        return
    if action is Action.UNSHELVE:
        os_.unshelve()
        state.touch()  # grace period starts from the wake, not the last poll
    elif action is Action.SHELVE:
        os_.shelve()


def run_once(
    settings: Settings, gh: GitHub, os_: OpenStack, state: State, dry_run: bool = False
) -> Action:
    obs = observe(gh, os_, state, settings.runner_label)
    action = decide(obs, settings.grace_seconds)
    log.info(
        "queued=%d busy=%s worker=%s idle=%s -> %s",
        obs.queued_jobs,
        obs.runner_busy,
        obs.worker_status,
        "n/a" if obs.idle_seconds is None else f"{obs.idle_seconds:.0f}s",
        action.value,
    )
    apply(action, os_, state, dry_run)
    return action


def run_forever(settings: Settings, gh: GitHub, os_: OpenStack, state: State) -> None:
    while True:
        try:
            run_once(settings, gh, os_, state)
        except Exception:
            log.exception("reconcile cycle failed; retrying next poll")
        time.sleep(settings.poll_seconds)
