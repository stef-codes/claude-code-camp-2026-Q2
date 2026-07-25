from __future__ import annotations

import json
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path


class Logger:
    DEFAULT_SESSION_DIR = "sessions"

    def __init__(
        self,
        *,
        session_id: str | None = None,
        dir: str | None = None,
        log: str | None = None,
        snapshot: dict | None = None,
    ) -> None:
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
        if self._log_io:
            self._log_io.close()

    def _default_dir(self) -> str:
        from . import config as get_config

        return str(Path(get_config().dir) / self.DEFAULT_SESSION_DIR)

    def _write_log(self, event: dict) -> None:
        event = {**event, "session_id": self.session_id, "at": datetime.now().astimezone().isoformat()}
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
