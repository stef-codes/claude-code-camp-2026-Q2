from __future__ import annotations

import json
import re
import secrets
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .telemetry import Noop


# Accumulates attributes for the span an `operation` block is running inside.
# Ruby's Operation::Frame also carries correlation ids for the CDC journal;
# this is the attribute-carrying half only, which is all the telemetry layer
# needs (see the operation() docstring).
class Frame:
    def __init__(self) -> None:
        self.attributes: dict = {}

    # Accepts a mapping, keywords, or both. A mapping is required for dotted
    # OTel keys, which are not legal Python keyword names:
    #   frame.set({"gen_ai.usage.input_tokens": 12})
    #   frame.set(provider="anthropic", model="claude-haiku-4-5")
    def set(self, mapping: dict | None = None, **kwargs) -> None:
        if mapping:
            self.attributes.update(mapping)
        if kwargs:
            self.attributes.update(kwargs)


class Logger:
    DEFAULT_SESSION_DIR = "sessions"

    DEFAULT_TASK = "player"

    def __init__(
        self,
        *,
        session_id: str | None = None,
        dir: str | None = None,
        log: str | None = None,
        snapshot: dict | None = None,
        task: str = DEFAULT_TASK,
        telemetry=None,
    ) -> None:
        self._task = str(task)
        # Noop unless a live exporter is passed in, so an unconfigured session
        # behaves exactly as it did before telemetry existed.
        self._telemetry = telemetry if telemetry is not None else Noop()
        self.session_id = session_id or self._generate_session_id()
        if log:
            self.path = log
        else:
            base = dir or self._default_dir()
            self.path = str(Path(base) / f"{self.session_id}.jsonl")

        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._log_io = open(self.path, "a")
        self._subscribers: list = []
        self._write_log({"phase": "session_start", **(snapshot or {})})

    # The task this logger is recording. Ruby keeps a task *stack* (delegated
    # sub-runs push onto it); step 12 has no delegation, so this is the single
    # configured name.
    @property
    def current_task(self) -> str:
        return self._task

    # An operation span: a unit of work that started, contained other things,
    # and finished. Yields a Frame whose `set` accumulates attributes that are
    # written to the span when the block closes; a raise still closes the span,
    # flagged with the error, rather than leaving it open.
    #
    # DEVIATION from Ruby, deliberate: Ruby's `Logger#operation` also writes
    # `operation_start`/`operation_end` records to the JSONL and mints
    # correlation ids for the change-data-capture journal. Those belong to the
    # week-2 Operation subsystem, which step 12 does not have. This emits
    # spans ONLY, so the on-disk log format is untouched — with tracing off,
    # a session's JSONL is byte-identical to one written before this port.
    @contextmanager
    def operation(
        self,
        name: str,
        *,
        trigger: str | None = None,
        kind: str = "internal",
        attributes: dict | None = None,
        root: bool = False,
    ):
        span_attributes = {
            "session.id": self.session_id,
            "boukensha.session_id": self.session_id,
            "boukensha.task": self.current_task,
            "boukensha.trigger": trigger,
            **(attributes or {}),
        }
        span_attributes = {k: v for k, v in span_attributes.items() if v is not None}

        with self._telemetry.in_span(
            name, kind=kind, attributes=span_attributes, root=root
        ) as span:
            frame = Frame()
            try:
                yield frame
            except Exception as e:
                span.record_exception(e)
                span.error(e)
                raise
            finally:
                span.set_attributes(self._otel_attributes(frame.attributes))

    # A key that already looks like an OTel attribute (it has a dot) passes
    # through; a bare key is namespaced. So `frame.set(model: ...)` becomes
    # `boukensha.model` while `gen_ai.request.model` is left alone.
    def _otel_attributes(self, attributes: dict) -> dict:
        out = {}
        for key, value in (attributes or {}).items():
            if value is None:
                continue
            name = str(key) if "." in str(key) else f"boukensha.{key}"
            out[name] = value
        return out

    def turn(self, *, n: int) -> None:
        self._write_log({"phase": "turn", "n": n})

    def iteration(self, *, n: int, max: int) -> None:
        self._write_log({"phase": "iteration", "n": n, "max": max})

    def limit_reached(self, *, kind: str, n: int, max: int) -> None:
        self._write_log({"phase": "limit_reached", "kind": kind, "n": n, "max": max})

    def turn_end(self, *, reason: str, iterations: int, tokens=None) -> None:
        self._write_log(
            {"phase": "turn_end", "reason": reason, "iterations": iterations, "tokens": tokens}
        )

    def prompt(self, *, messages: list, tools: dict, context_window=None) -> None:
        self._write_log(
            {
                "phase": "prompt",
                "message_count": len(messages),
                "messages": [self._serialize_message(m) for m in messages],
                "tool_count": len(tools),
                "tools": list(tools.keys()),
                "context_window": context_window,
            }
        )

    def compaction(self, *, before, dropped, context_window=None) -> None:
        self._write_log(
            {"phase": "compaction", "before": before, "dropped": dropped, "context_window": context_window}
        )

    def tool_call(self, *, name: str, args) -> None:
        self._write_log({"phase": "tool_call", "name": name, "args": args})

    def tool_result(self, *, name: str, result, ok: bool = True, error=None) -> None:
        self._write_log(
            {"phase": "tool_result", "name": name, "result": str(result), "ok": ok, "error": error}
        )

    def response(self, *, text, usage=None, stop_reason=None, task=None, backend=None) -> None:
        event = {
            "phase": "response",
            "text": str(text).strip(),
            "usage": usage,
            "stop_reason": stop_reason,
        }
        event.update(self._execution_metadata(task=task, backend=backend, usage=usage))
        self._write_log(event)

    def reasoning(self, *, text, redacted: bool = False) -> None:
        self._write_log({"phase": "reasoning", "text": str(text), "redacted": redacted})

    def plan(self, *, text) -> None:
        self._write_log({"phase": "plan", "text": str(text).strip()})

    def raw(self, *, data) -> None:
        from . import is_debug

        if not is_debug():
            return
        self._write_log({"phase": "raw", "data": data})

    def subscribe(self, callback) -> None:
        self._subscribers.append(callback)

    def close(self) -> None:
        # Flush before the process can exit: a short-lived run would otherwise
        # drop the batch still sitting in the exporter's queue. Ruby's timeout
        # is in seconds and is converted inside the exporter.
        self._telemetry.force_flush(timeout=5)
        if self._log_io:
            self._log_io.close()

    def _default_dir(self) -> str:
        from . import config as get_config

        return str(Path(get_config().dir) / self.DEFAULT_SESSION_DIR)

    def _write_log(self, event: dict) -> None:
        # Attach the event to the ambient span, then stamp the JSONL line with
        # the ids of the span it happened inside, so a log line and a trace can
        # be joined after the fact. `current_ids` is empty for Noop, which is
        # what keeps the log format unchanged when tracing is off.
        self._telemetry.capture_event(event)
        correlation = self._telemetry.current_ids()
        event = {
            **event,
            **correlation,
            "session_id": self.session_id,
            "at": datetime.now().astimezone().isoformat(),
        }
        self._log_io.write(json.dumps(event) + "\n")
        self._log_io.flush()
        for subscriber in self._subscribers:
            subscriber(event)

    def _generate_session_id(self) -> str:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        return f"{timestamp}-{secrets.token_hex(4)}"

    def _serialize_message(self, msg) -> dict:
        return {"role": msg.role, "content": msg.content}

    def _execution_metadata(self, *, task, backend, usage) -> dict:
        if not (task or backend or usage):
            return {}

        tokens = self._usage_tokens(usage)
        metadata = {
            "task": self._task_name(task),
            "provider": self._provider_name(backend),
            "model": getattr(backend, "model", None) if backend else None,
            "usage_unit": getattr(backend, "usage_unit", None) if backend else None,
            "usage_level": getattr(backend, "usage_level", None) if backend else None,
            "input_tokens": tokens["input"],
            "output_tokens": tokens["output"],
            "cost_usd": self._estimate_cost(backend, tokens),
        }
        return {k: v for k, v in metadata.items() if v is not None}

    def _task_name(self, task):
        if task is None:
            return None
        if hasattr(task, "task_name"):
            return task.task_name()
        return str(task)

    def _provider_name(self, backend) -> str | None:
        if backend is None:
            return None
        name = type(backend).__name__
        return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()

    def _usage_tokens(self, usage) -> dict:
        usage = usage or {}
        return {
            "input": self._first_integer(
                usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"
            ),
            "output": self._first_integer(
                usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count"
            ),
        }

    def _first_integer(self, mapping: dict, *keys):
        for key in keys:
            value = mapping.get(key)
            if value is not None:
                try:
                    return int(value)
                except (TypeError, ValueError):
                    return None
        return None

    def _estimate_cost(self, backend, tokens):
        if backend is None or not hasattr(backend, "estimate_cost"):
            return None
        if tokens["input"] is None or tokens["output"] is None:
            return None
        return backend.estimate_cost(input_tokens=tokens["input"], output_tokens=tokens["output"])
