from __future__ import annotations

import sys

from .noop import Noop, NoopSpan

# The instrumentation contract. Attribute changes require an explicit
# compatibility review even when SDK dependencies are upgraded — see
# week2_capable/observability/README.md.
SEMANTIC_CONVENTIONS = "OpenTelemetry GenAI semantic conventions 1.37.0"

__all__ = ["Noop", "NoopSpan", "SEMANTIC_CONVENTIONS", "build"]


# Returns a live exporter when tracing is enabled and configured, and a Noop in
# every other case — including when the opentelemetry packages are not
# installed. A broken or absent tracing setup must never take the agent down
# with it, so the failure path warns once and degrades.
def build(*, config, warning_io=None) -> object:
    warning_io = warning_io if warning_io is not None else sys.stderr

    if not config.otel_enabled():
        return Noop()

    try:
        from .open_telemetry import OpenTelemetry

        return OpenTelemetry(
            capture_content=config.otel_capture_content(),
            content_max_bytes=config.otel_content_max_bytes(),
            warning_io=warning_io,
        )
    except Exception as e:  # noqa: BLE001 - ImportError included, as in Ruby
        print(
            f"boukensha: OpenTelemetry disabled: {type(e).__name__}: {e}",
            file=warning_io,
        )
        return Noop()
