import json

import pytest

from yt_controller.config import ConfigError, Settings
from yt_controller.idle_shelver import should_shelve
from yt_controller.reconcile import Action, Observation, decide, observe
from yt_controller.state import State

GRACE = 300


def obs(queued=0, busy=False, status="SHELVED_OFFLOADED", idle=None):
    return Observation(
        queued_jobs=queued, runner_busy=busy, worker_status=status, idle_seconds=idle
    )


@pytest.mark.parametrize("status", ["SHELVED_OFFLOADED", "SHELVED", "shelved_offloaded"])
@pytest.mark.parametrize("queued,busy", [(1, False), (0, True), (3, True)])
def test_wanted_and_shelved_unshelves(status, queued, busy):
    assert decide(obs(queued, busy, status), GRACE) is Action.UNSHELVE


@pytest.mark.parametrize("queued,busy", [(1, False), (0, True)])
@pytest.mark.parametrize("status", ["ACTIVE", "UNSHELVING", "SHELVING", "ERROR"])
def test_wanted_and_not_shelved_does_nothing(status, queued, busy):
    assert decide(obs(queued, busy, status, idle=10_000), GRACE) is Action.NONE


def test_idle_active_past_grace_shelves():
    assert decide(obs(status="ACTIVE", idle=GRACE + 1), GRACE) is Action.SHELVE


def test_idle_active_within_grace_waits():
    assert decide(obs(status="ACTIVE", idle=GRACE - 1), GRACE) is Action.NONE
    assert decide(obs(status="ACTIVE", idle=GRACE), GRACE) is Action.NONE


def test_idle_active_with_unknown_idle_waits():
    # No recorded activity yet (fresh state file): never shelve on a guess.
    assert decide(obs(status="ACTIVE", idle=None), GRACE) is Action.NONE


@pytest.mark.parametrize(
    "status", ["SHELVED_OFFLOADED", "SHELVING", "UNSHELVING", "ERROR", "BUILD"]
)
def test_idle_non_active_does_nothing(status):
    assert decide(obs(status=status, idle=10_000), GRACE) is Action.NONE


def test_idle_shelver_only_fires_on_active_unwanted_past_limit():
    assert should_shelve("ACTIVE", wanted=False, idle_seconds=1201, limit=1200)
    assert not should_shelve("ACTIVE", wanted=True, idle_seconds=1201, limit=1200)
    assert not should_shelve("ACTIVE", wanted=False, idle_seconds=1199, limit=1200)
    assert not should_shelve("SHELVED_OFFLOADED", wanted=False, idle_seconds=99_999, limit=1200)
    assert not should_shelve("UNSHELVING", wanted=False, idle_seconds=99_999, limit=1200)


class FakeGitHub:
    def __init__(self, queued=0, busy=False):
        self._queued, self._busy = queued, busy

    def queued_jobs(self, label):
        return self._queued

    def runner_busy(self, label):
        return self._busy


class FakeOpenStack:
    worker_name = "yt-worker"

    def __init__(self, status):
        self._status = status

    def status(self):
        return self._status


def test_observe_touches_state_when_wanted(tmp_path):
    state = State(tmp_path / "state.json")
    o = observe(FakeGitHub(queued=2), FakeOpenStack("ACTIVE"), state, "jetstream", now=1000.0)
    assert o.idle_seconds == 0.0
    assert state.last_activity() == 1000.0


def test_observe_measures_idle_from_last_activity(tmp_path):
    state = State(tmp_path / "state.json")
    state.touch(1000.0)
    o = observe(FakeGitHub(), FakeOpenStack("ACTIVE"), state, "jetstream", now=1400.0)
    assert o.idle_seconds == 400.0
    assert decide(o, GRACE) is Action.SHELVE


def test_observe_idle_unknown_without_state(tmp_path):
    state = State(tmp_path / "state.json")
    o = observe(FakeGitHub(), FakeOpenStack("ACTIVE"), state, "jetstream", now=1400.0)
    assert o.idle_seconds is None


def test_state_survives_corrupt_file(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("{not json")
    state = State(path)
    assert state.last_activity() is None
    state.touch(5.0)
    assert json.loads(path.read_text()) == {"last_activity": 5.0}


def test_settings_from_env_defaults():
    s = Settings.from_env({"GITHUB_REPO": "chrishavlin/yt", "GITHUB_TOKEN": "x"})
    assert s.worker_name == "yt-worker"
    assert s.grace_seconds == 300
    assert s.idle_shelve_seconds > s.grace_seconds


def test_settings_from_env_requires_repo_and_token():
    with pytest.raises(ConfigError):
        Settings.from_env({"GITHUB_REPO": "chrishavlin/yt"})
    with pytest.raises(ConfigError):
        Settings.from_env({"GITHUB_REPO": "nope", "GITHUB_TOKEN": "x"})
