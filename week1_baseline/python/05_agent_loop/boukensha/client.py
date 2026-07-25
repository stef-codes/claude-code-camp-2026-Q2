from __future__ import annotations

import json
import socket
import ssl
import time
import urllib.error
import urllib.request
from http.client import HTTPException

from .errors import ApiError


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

    def __init__(self, builder) -> None:
        self.builder = builder

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
                with urllib.request.urlopen(request) as resp:
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
