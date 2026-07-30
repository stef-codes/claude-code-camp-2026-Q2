from __future__ import annotations

from contextlib import contextmanager

# The null object every session gets when tracing is off, which is the
# default. Every method is a no-op that returns the shape a caller expects, so
# the logger and agent never branch on "is telemetry enabled" — they always
# have a span to talk to.
#
# Ruby names the error method `error!`; `!` is not legal in a Python
# identifier, so it is `error` here and in OpenTelemetry.Span alike.


class NoopSpan:
    @property
    def trace_id(self):
        return None

    @property
    def span_id(self):
        return None

    def propagation_carrier(self) -> dict:
        return {}

    def set_attributes(self, attributes) -> None:
        return None

    def add_event(self, name, *, attributes=None) -> None:
        return None

    def record_exception(self, exception) -> None:
        return None

    def error(self, exception=None) -> None:
        return None


class Noop:
    @contextmanager
    def in_span(self, name, *, kind: str = "internal", attributes=None, root: bool = False):
        yield NoopSpan()

    def current_ids(self) -> dict:
        return {}

    def propagation_carrier(self) -> dict:
        return {}

    def capture_event(self, event) -> None:
        return None

    def force_flush(self, timeout=None) -> bool:
        return True

    def shutdown(self, timeout=None) -> bool:
        return True
