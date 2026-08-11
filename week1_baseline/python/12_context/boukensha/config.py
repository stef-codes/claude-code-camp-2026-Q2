from __future__ import annotations

import os
from pathlib import Path

import yaml
from dotenv import load_dotenv


class Config:
    # The .boukensha config directory is resolved in this order:
    #   1. BOUKENSHA_DIR environment variable (set before loading .env)
    #   2. ~/.boukensha  (default)
    DEFAULT_DIR = str(Path.home() / ".boukensha")

    # Default prompts shipped alongside the library code.
    PROMPTS_DIR = str(Path(__file__).resolve().parent.parent / "prompts")

    # settings file name tried in order; supports both extensions.
    SETTINGS_FILENAMES = ("settings.yaml", "settings.yml")

    def __init__(self) -> None:
        self.dir = self._resolve_dir()
        self._load_env()
        self.settings = self._load_settings()

    # ---------- tasks -----------------------------------------------------

    # With no argument: returns the full tasks dict from settings.yaml.
    # With a name: returns that task's settings dict, e.g. tasks("player").
    def tasks(self, name: str | None = None) -> dict | None:
        all_tasks = self.dig("tasks") or {}
        if name is None:
            return all_tasks
        return all_tasks.get(str(name))

    # The user's prompts directory for task prompt overrides.
    @property
    def user_prompts_dir(self) -> str:
        return os.path.join(self.dir, "prompts")

    # ---------- provider --------------------------------------------------

    def provider_type(self) -> str:
        return self.dig("tasks", "player", "provider") or "anthropic"

    def model(self) -> str:
        return self.dig("tasks", "player", "model") or "claude-haiku-4-5"

    # ---------- MCP servers ------------------------------------------------

    # MCP servers to plug into the agent, keyed by name. This is where ALL
    # of the agent's tools come from — boukensha ships none of its own:
    #
    #   mcp_servers:
    #     mud:
    #       command: mud-manager
    #       args:    [--mcp]
    #       prefix:  tbamud
    #       env:
    #         MUD_HOST: your.mud.host      # a stdio server's credentials
    #         MUD_NAME: Gandalf            # travel by environment
    #
    # Returns {"mud": {command:, args:, env:, prefix:, required:}} with
    # defaults applied. required=False lets a server fail to spawn without
    # taking the agent down with it.
    def mcp_servers(self) -> dict:
        out = {}
        for name, raw in (self.dig("mcp_servers") or {}).items():
            entry = raw if isinstance(raw, dict) else {}
            required = entry.get("required")
            prefix = entry.get("prefix")

            out[str(name)] = {
                "command": str(entry.get("command") or ""),
                "args": [str(a) for a in (entry.get("args") or [])],
                "env": {str(k): str(v) for k, v in (entry.get("env") or {}).items()},
                "prefix": str(prefix) if prefix is not None else None,
                "required": True if required is None else bool(required),
            }
        return out

    # ---------- agent limits ----------------------------------------------
    # Static per-turn circuit breakers, read where the agent is constructed.
    # A value of 0 or None means "disabled" (no ceiling) — useful for debugging.

    def agent_max_iterations(self) -> int:
        v = self.dig("agent", "max_iterations")
        return 25 if v is None else int(v)

    def agent_max_output_tokens(self) -> int:
        v = self.dig("agent", "max_output_tokens")
        return 1024 if v is None else int(v)

    def agent_max_turn_tokens(self) -> int:
        v = self.dig("agent", "max_turn_tokens")
        return 60_000 if v is None else int(v)

    def agent_compaction_threshold(self) -> float:
        v = self.dig("agent", "compaction_threshold")
        return 0.85 if v is None else float(v)

    # ---------- observability ---------------------------------------------
    # Tracing is OFF by default. The endpoint and credentials are not read
    # here: they come from standard OTEL_EXPORTER_OTLP_* environment variables
    # (loaded from .boukensha/.env by _load_env), so switching backends never
    # touches settings.yaml.

    def otel_enabled(self) -> bool:
        return self._env_boolean(
            "BOUKENSHA_OTEL_ENABLED", self.dig("observability", "otel", "enabled"), False
        )

    # OFF by default on purpose: with this false only metadata leaves the
    # process (model, provider, token counts, latency, span names). Turning it
    # on ships prompts and tool payloads to whatever OTLP endpoint is
    # configured.
    def otel_capture_content(self) -> bool:
        return self._env_boolean(
            "BOUKENSHA_OTEL_CAPTURE_CONTENT",
            self.dig("observability", "otel", "capture_content"),
            False,
        )

    def otel_content_max_bytes(self) -> int:
        raw = os.environ.get("BOUKENSHA_OTEL_CONTENT_MAX_BYTES")
        if raw is None:
            raw = self.dig("observability", "otel", "content_max_bytes") or 4096
        value = int(raw)
        if value <= 0:
            raise ValueError("BOUKENSHA_OTEL_CONTENT_MAX_BYTES must be positive")
        return value

    # ---------- low-level helpers -----------------------------------------

    # Env var wins over the YAML value; an unset/None pair falls back to
    # `default`. An unparseable value raises rather than being silently
    # treated as false — a typo'd BOUKENSHA_OTEL_ENABLED=ture should not
    # quietly disable tracing.
    @staticmethod
    def _env_boolean(name: str, yaml_value, default: bool) -> bool:
        raw = os.environ[name] if name in os.environ else yaml_value
        if raw is None:
            return default
        if raw is True or raw is False:
            return raw
        text = str(raw).lower()
        if text in ("1", "true", "yes", "on"):
            return True
        if text in ("0", "false", "no", "off"):
            return False
        raise ValueError(f"{name} must be true or false")

    # Fetch a nested key path from settings, e.g. dig("tasks", "player")
    def dig(self, *keys: str):
        node = self.settings
        for key in keys:
            if not isinstance(node, dict):
                return None
            node = node.get(str(key))
        return node

    def __repr__(self) -> str:
        return f"#<Boukensha::Config dir={self.dir} provider={self.provider_type()} model={self.model()}>"

    __str__ = __repr__

    # ---------- private -----------------------------------------------

    def _resolve_dir(self) -> str:
        raw = os.environ.get("BOUKENSHA_DIR") or self.DEFAULT_DIR
        return str(Path(raw).expanduser().resolve())

    def _load_env(self) -> None:
        env_file = Path(self.dir) / ".env"
        if env_file.exists():
            load_dotenv(env_file)

    def _load_settings(self) -> dict:
        for filename in self.SETTINGS_FILENAMES:
            settings_file = Path(self.dir) / filename
            if settings_file.exists():
                return yaml.safe_load(settings_file.read_text()) or {}
        return {}
