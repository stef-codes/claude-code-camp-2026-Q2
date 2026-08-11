from __future__ import annotations

import http.client
import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
from http.client import HTTPException

from .errors import ApiError


# ---------------------------------------------------------------------------
# IPv4-preferring transport
#
# When a host publishes an AAAA record whose path is blackholed, every request
# pays the OS TCP timeout (~75s on macOS) before falling back to IPv4:
# socket.create_connection walks getaddrinfo results SEQUENTIALLY with a
# blocking connect. curl does not suffer this because it implements Happy
# Eyeballs (RFC 8305) — parallel attempts with a short head start. Python's
# stdlib has no equivalent, so we filter to IPv4 instead.
#
# Set BOUKENSHA_FORCE_IPV4=false to opt out. Keep that in mind on an IPv6-only
# network, where forcing IPv4 turns a slow connection into a failed one.
# ---------------------------------------------------------------------------


def _force_ipv4() -> bool:
    return os.environ.get("BOUKENSHA_FORCE_IPV4", "true").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )


def _ipv4_create_connection(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None):
    host, port = address[0], address[1]
    last_error: Exception | None = None
    for family, socktype, proto, _canon, sa in socket.getaddrinfo(
        host, port, socket.AF_INET, socket.SOCK_STREAM
    ):
        sock = None
        try:
            sock = socket.socket(family, socktype, proto)
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)
            if source_address:
                sock.bind(source_address)
            sock.connect(sa)
            return sock
        except OSError as e:
            last_error = e
            if sock is not None:
                sock.close()
    if last_error is not None:
        raise last_error
    raise OSError(f"no IPv4 address for {host!r}")


class _IPv4HTTPSConnection(http.client.HTTPSConnection):
    # HTTPConnection.__init__ assigns _create_connection per instance, so the
    # override has to happen after super().__init__ rather than as a class attr.
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._create_connection = _ipv4_create_connection


class _IPv4HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_IPv4HTTPSConnection, req, context=self._context)


_opener_cache: dict[bool, urllib.request.OpenerDirector] = {}


# Plain-HTTP backends (a local Ollama on http://localhost) keep the stock
# handler: localhost has no blackholed AAAA to route around.
def _opener() -> urllib.request.OpenerDirector:
    forced = _force_ipv4()
    if forced not in _opener_cache:
        _opener_cache[forced] = (
            urllib.request.build_opener(_IPv4HTTPSHandler())
            if forced
            else urllib.request.build_opener()
        )
    return _opener_cache[forced]


class Client:
    RETRYABLE_STATUS_CODES = {408, 409, 429, 500, 502, 503, 504}
    TRANSIENT_ERRORS = (
        EOFError,
        ConnectionResetError,
        ConnectionRefusedError,
        TimeoutError,
        ssl.SSLError,
        socket.gaierror,
        HTTPException,
    )
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5
    # A ceiling, not a tuning knob — without it a stalled socket blocks the
    # agent forever, which is how a wedged turn used to look like a hung REPL.
    REQUEST_TIMEOUT = 300.0

    def __init__(self, builder) -> None:
        self.builder = builder
        self._opener = _opener()

    def call(self, *, max_output_tokens: int = 1024, tools: list | None = None) -> dict:
        body = json.dumps(
            self.builder.to_api_payload(max_output_tokens=max_output_tokens, tools=tools)
        ).encode("utf-8")
        request = urllib.request.Request(
            self.builder.url, data=body, headers=self.builder.headers, method="POST"
        )

        attempts = 0
        status = None
        response_body = None

        while True:
            attempts += 1

            try:
                # REQUEST_TIMEOUT is deliberately generous: urllib applies one
                # value to both connect and read, so anything tight enough to
                # bound a connect would also abort a slow-but-healthy
                # generation — and a read timeout raises TimeoutError, which
                # this loop retries, billing the same completion again.
                with self._opener.open(request, timeout=self.REQUEST_TIMEOUT) as resp:
                    status = resp.status
                    response_body = resp.read().decode("utf-8")
            except urllib.error.HTTPError as e:
                status = e.code
                response_body = e.read().decode("utf-8")
            except self.TRANSIENT_ERRORS as e:
                if attempts > self.MAX_RETRIES:
                    raise ApiError(
                        f"API request failed after {attempts} attempts: "
                        f"{type(e).__name__}: {e}"
                    ) from e
                time.sleep(self._retry_delay(attempts))
                continue

            if self._retryable_response(status) and attempts <= self.MAX_RETRIES:
                time.sleep(self._retry_delay(attempts))
                continue

            break

        if not (200 <= status < 300):
            plural = "" if attempts == 1 else "s"
            raise ApiError(
                f"API request failed after {attempts} attempt{plural} "
                f"({status}): {response_body}"
            )

        return json.loads(response_body)

    def _retryable_response(self, status: int) -> bool:
        return status in self.RETRYABLE_STATUS_CODES

    def _retry_delay(self, attempt: int) -> float:
        return self.BASE_RETRY_DELAY * (2 ** (attempt - 1))
