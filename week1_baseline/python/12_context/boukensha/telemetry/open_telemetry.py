from __future__ import annotations

import json
import os
import re
import sys
from contextlib import contextmanager

from opentelemetry import context as otel_context
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.propagate import inject
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

from ..version import VERSION

# Guards SDK configuration so a second Logger in the same process does not
# install a second TracerProvider (Ruby uses a class-level ivar for this).
_CONFIGURED = False

KIND = {
    "internal": trace.SpanKind.INTERNAL,
    "client": trace.SpanKind.CLIENT,
    "server": trace.SpanKind.SERVER,
    "producer": trace.SpanKind.PRODUCER,
    "consumer": trace.SpanKind.CONSUMER,
}

# Content phases that may carry payloads. Anything not listed here is metadata
# only and is never emitted as a content event, even with capture_content on.
CONTENT_PHASES = (
    "prompt",
    "request",
    "response",
    "tool_call",
    "tool_result",
    "injected_context",
    "context_transform",
)

SECRET_KEY = re.compile(r"(authorization|api[_-]?key|token|password|secret|credential)", re.I)
SECRET_VALUE = re.compile(r"(Bearer\s+)[^\s]+|\bsk-[A-Za-z0-9_-]{8,}", re.I)


class Span:
    def __init__(self, span) -> None:
        self._span = span

    @property
    def trace_id(self):
        ctx = self._span.get_span_context()
        return trace.format_trace_id(ctx.trace_id) if ctx.is_valid else None

    @property
    def span_id(self):
        ctx = self._span.get_span_context()
        return trace.format_span_id(ctx.span_id) if ctx.is_valid else None

    def set_attributes(self, attributes) -> None:
        for key, value in (attributes or {}).items():
            if value is not None:
                self._span.set_attribute(str(key), value)

    def add_event(self, name, *, attributes=None) -> None:
        payload = {str(k): v for k, v in (attributes or {}).items() if v is not None}
        self._span.add_event(str(name), attributes=payload)

    def record_exception(self, exception) -> None:
        self._span.record_exception(exception)

    def error(self, exception=None) -> None:
        if exception is not None:
            self._span.set_attribute("error.type", type(exception).__name__)
        self._span.set_status(
            Status(StatusCode.ERROR, str(exception) if exception is not None else None)
        )


class OpenTelemetry:
    # `error.type` in Ruby is the exception's fully-qualified class name
    # (`Boukensha::ApiError`); Python has no direct equivalent, so this uses the
    # bare class name (`ApiError`).
    def __init__(
        self,
        *,
        capture_content: bool = False,
        content_max_bytes: int = 4096,
        warning_io=None,
    ) -> None:
        self._capture_content = capture_content
        self._content_max_bytes = content_max_bytes
        self._warning_io = warning_io if warning_io is not None else sys.stderr
        self._warned = False
        self._configure_once()
        self._tracer = trace.get_tracer("boukensha", VERSION)

    @contextmanager
    def in_span(self, name, *, kind: str = "internal", attributes=None, root: bool = False):
        # An empty Context has no active span, which is what makes the new span
        # a trace root rather than a child of whatever is ambient.
        parent = otel_context.Context() if root else otel_context.get_current()
        span = self._tracer.start_span(
            str(name),
            context=parent,
            kind=KIND[kind],
            attributes=self._clean(attributes or {}),
        )
        ctx = trace.set_span_in_context(span, context=parent)
        token = otel_context.attach(ctx)
        try:
            yield Span(span)
        finally:
            otel_context.detach(token)
            span.end()

    def current_ids(self) -> dict:
        ctx = trace.get_current_span().get_span_context()
        if not ctx.is_valid:
            return {}
        return {
            "trace_id": trace.format_trace_id(ctx.trace_id),
            "span_id": trace.format_span_id(ctx.span_id),
        }

    def propagation_carrier(self) -> dict:
        carrier: dict = {}
        inject(carrier)
        return carrier

    # Attach a log event to the ambient span. Metadata-only by default: with
    # capture_content off, the ONLY thing this emits is the boolean fact that
    # the model produced reasoning — never its text, and never any payload.
    def capture_event(self, event) -> None:
        try:
            phase = str(event.get("phase") or "")
            span = trace.get_current_span()
            if not span.get_span_context().is_valid:
                return

            if phase == "reasoning":
                span.add_event(
                    "boukensha.reasoning", attributes={"boukensha.reasoning.present": True}
                )
                return
            if not self._capture_content:
                return
            if phase not in CONTENT_PHASES:
                return

            raw = json.dumps(self._redact(event))
            data = raw.encode("utf-8")
            truncated = len(data) > self._content_max_bytes
            if truncated:
                # errors="replace" is Ruby's String#scrub: a cut mid-codepoint
                # yields U+FFFD rather than raising.
                raw = data[: self._content_max_bytes].decode("utf-8", errors="replace")
            span.add_event(
                f"boukensha.{phase}",
                attributes={"boukensha.content": raw, "boukensha.content.truncated": truncated},
            )
        except Exception as e:  # noqa: BLE001 - telemetry never breaks the session
            self._warn_once(e)

    # Ruby takes these timeouts in SECONDS; the Python SDK takes milliseconds.
    # The seconds-based signature is kept for parity with the Ruby call sites
    # (`logger.close` passes 5) and converted here.
    def force_flush(self, timeout=None) -> bool:
        try:
            provider = trace.get_tracer_provider()
            if timeout is None:
                return bool(provider.force_flush())
            return bool(provider.force_flush(timeout_millis=int(timeout * 1000)))
        except Exception as e:  # noqa: BLE001
            self._warn_once(e)
            return False

    # TracerProvider.shutdown() takes no timeout in Python; the argument is
    # accepted for call-site parity and ignored.
    def shutdown(self, timeout=None) -> bool:
        try:
            trace.get_tracer_provider().shutdown()
            return True
        except Exception as e:  # noqa: BLE001
            self._warn_once(e)
            return False

    # ---------- private ---------------------------------------------------

    def _configure_once(self) -> None:
        global _CONFIGURED
        if _CONFIGURED:
            return

        resource = Resource.create(
            {SERVICE_NAME: os.environ.get("OTEL_SERVICE_NAME", "boukensha")}
        )
        provider = TracerProvider(resource=resource)
        # OTLPSpanExporter reads OTEL_EXPORTER_OTLP_TRACES_ENDPOINT and
        # OTEL_EXPORTER_OTLP_TRACES_HEADERS itself. Ruby gets the processor
        # wired implicitly by SDK.configure; Python has to say it out loud.
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        trace.set_tracer_provider(provider)
        _CONFIGURED = True

    # OTel accepts scalars and homogeneous scalar arrays; anything else (a
    # nested dict, say) is DROPPED rather than stringified, matching Ruby.
    # Booleans are valid scalars but — as in Ruby, where `true` is not
    # Numeric — are not valid array members.
    def _clean(self, attributes) -> dict:
        out = {}
        for key, value in (attributes or {}).items():
            if value is None:
                continue
            if isinstance(value, (str, int, float, bool)):
                out[str(key)] = value
            elif isinstance(value, (list, tuple)) and all(
                not isinstance(i, bool) and isinstance(i, (str, int, float)) for i in value
            ):
                out[str(key)] = list(value)
        return out

    def _redact(self, value, key=None):
        if key is not None and SECRET_KEY.search(str(key)):
            return "[REDACTED]"

        if isinstance(value, dict):
            return {k: self._redact(v, str(k)) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self._redact(v) for v in value]
        if isinstance(value, str):
            # The `Bearer ` test is case-SENSITIVE while the pattern is not, so
            # `bearer abc` is replaced wholesale and `Bearer abc` keeps its
            # scheme. That asymmetry is Ruby's; preserved deliberately.
            def sub(m):
                return "Bearer [REDACTED]" if m.group(0).startswith("Bearer ") else "[REDACTED]"

            return SECRET_VALUE.sub(sub, value)
        return value

    def _warn_once(self, error) -> None:
        if self._warned:
            return
        self._warned = True
        print(
            f"boukensha: OpenTelemetry export failed: {type(error).__name__}: {error}",
            file=self._warning_io,
        )
