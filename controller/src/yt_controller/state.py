"""Tiny JSON file recording when the reconciler last saw activity."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path


class State:
    def __init__(self, path: Path):
        self.path = path

    def _read(self) -> dict:
        try:
            return json.loads(self.path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        os.replace(tmp, self.path)

    def last_activity(self) -> float | None:
        value = self._read().get("last_activity")
        return float(value) if value is not None else None

    def touch(self, now: float | None = None) -> None:
        data = self._read()
        data["last_activity"] = time.time() if now is None else now
        self._write(data)
