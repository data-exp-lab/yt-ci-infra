"""HTTP endpoint the worker hits once at boot to receive a single-use runner config.

GET /runner-config  ->  {"runner_name": ..., "encoded_jit_config": ...}

No authentication: reachability is the credential. The security group admits this port only
from the worker's security group over the private network. Keep it that way.
"""

from __future__ import annotations

import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .config import Settings
from .github import GitHub
from .state import State

log = logging.getLogger(__name__)


def make_handler(settings: Settings, gh: GitHub, state: State):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path != "/runner-config":
                self.send_error(404)
                return
            try:
                payload = gh.generate_jitconfig(settings.runner_label)
            except Exception:
                log.exception("generate-jitconfig failed")
                self.send_error(502, "could not mint runner config")
                return
            state.touch()
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            log.info(
                "issued runner config %s to %s", payload["runner_name"], self.client_address[0]
            )

        def log_message(self, format, *args):  # noqa: A002
            log.debug(format, *args)

    return Handler


def serve(
    settings: Settings, gh: GitHub, state: State, background: bool = False
) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(
        (settings.token_bind, settings.token_port), make_handler(settings, gh, state)
    )
    log.info("runner-config endpoint on %s:%d", settings.token_bind, settings.token_port)
    if background:
        threading.Thread(target=server.serve_forever, daemon=True, name="tokens").start()
    else:
        server.serve_forever()
    return server
