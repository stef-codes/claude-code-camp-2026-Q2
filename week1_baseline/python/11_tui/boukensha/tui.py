from __future__ import annotations

import ctypes
import threading
import time
from datetime import datetime

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import Input, RichLog, Static

from .agent import Agent

# Tui wraps a Repl instance and replaces its raw print/input I/O with a
# structured four-zone display, using Textual as the Python substitute for
# Ruby's charm (bubbletea + lipgloss + bubbles) — there is no Python binding
# for bubbletea itself, so this is a from-scratch rebuild against Textual's
# own (Elm-inspired) app model, not a literal translation of tui.rb.
#
# The Repl continues to own session logic (turn counting, /commands, Agent
# dispatch). Tui registers output/event callbacks on the Repl and drives the
# Textual event loop.
#
# Layout (top -> bottom):
#   ┌──────────────────────────────────────────────┐
#   │  conversation viewport (scrollable)           │
#   ├──────────────────────────────────────────────┤
#   │  ⟳ live progress line (hidden when idle)     │
#   ├──────────────────────────────────────────────┤
#   │  boukensha> input box                         │
#   ├──────────────────────────────────────────────┤
#   │  status line (always-on)                      │
#   └──────────────────────────────────────────────┘
SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
TICK_S = 0.06


def _fmt_tokens(n) -> str:
    n = int(n or 0)
    return f"{n / 1000.0:.1f}k" if n >= 1000 else str(n)


def _async_raise(thread_id: int | None, exc_type: type) -> None:
    # Best-effort analogue of Ruby's Thread#raise(Interrupt): CPython has no
    # first-class API for injecting an exception into another running
    # thread, so this uses PyThreadState_SetAsyncExc directly. Like Ruby's
    # Thread#raise against blocking I/O, this can only take effect at the
    # next bytecode/interpreter checkpoint — it is not guaranteed to
    # interrupt a blocking C-level socket read instantly.
    if thread_id is None:
        return
    result = ctypes.pythonapi.PyThreadState_SetAsyncExc(
        ctypes.c_long(thread_id), ctypes.py_object(exc_type)
    )
    if result > 1:
        ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_long(thread_id), None)


class Tui(App):
    CSS = """
    Screen {
        layout: vertical;
    }
    #viewport {
        height: 1fr;
        border: none;
        scrollbar-size-vertical: 1;
    }
    #progress {
        height: 1;
        padding: 0 1;
    }
    #input {
        height: 3;
    }
    #status {
        height: 1;
        background: $panel;
    }
    """

    BINDINGS = [
        Binding("escape", "interrupt_turn", "Interrupt", show=False),
        Binding("ctrl+l", "clear_history", "Clear", show=False),
        Binding("pageup", "scroll_up", "Scroll up", show=False),
        Binding("pagedown", "scroll_down", "Scroll down", show=False),
        Binding("ctrl+c", "quit", "Quit", show=False),
        Binding("ctrl+d", "quit", "Quit", show=False),
    ]

    def __init__(self, repl) -> None:
        super().__init__()
        self.repl = repl
        self.context = repl.context

        self._turn_count = 0
        self._session_input_tokens = 0
        self._session_output_tokens = 0
        self._turn_thread: threading.Thread | None = None

        self._live_active = False
        self._spinner_idx = 0
        self._turn_start_time: float | None = None
        self._elapsed = 0.0
        self._current_action = "idle"
        self._iteration = 0
        self._tool_call_count = 0
        self._turn_input_tokens = 0
        self._turn_output_tokens = 0

    def start(self) -> None:
        self.run()

    # ── Textual app lifecycle ───────────────────────────────────────────

    def compose(self) -> ComposeResult:
        # markup=False: viewport content is plain text (banner, conversation,
        # results, error strings) — none of it is meant to be interpreted as
        # Rich markup, and doing so would mis-render literal brackets like
        # "[error]" or a bracketed MUD room name.
        yield RichLog(id="viewport", wrap=True, markup=False, highlight=False)
        yield Static("", id="progress")
        yield Input(placeholder="Type a message…", id="input")
        yield Static("", id="status")

    def on_mount(self) -> None:
        self.query_one("#viewport", RichLog).write(self.repl.banner())

        self.repl.on_output(self._on_repl_output)
        self.repl.logger.subscribe(self._on_logger_event)

        self.query_one("#input", Input).focus()
        self.set_interval(TICK_S, self._tick)
        self._render_progress()
        self._render_status()

    # ── Repl/Logger callbacks ───────────────────────────────────────────
    #
    # These fire from two different call sites: directly on the UI thread
    # (slash commands, handled inline from on_input_submitted) and from the
    # background turn thread (Agent output/events during run_turn).
    # call_from_thread is only valid to call *from* a thread other than the
    # app's own — so route accordingly instead of always marshaling.

    def _on_repl_output(self, text: str) -> None:
        if threading.current_thread() is self._turn_thread:
            self.call_from_thread(self._write_line, text)
        else:
            self._write_line(text)

    def _write_line(self, text: str) -> None:
        self.query_one("#viewport", RichLog).write(text)

    def _on_logger_event(self, event: dict) -> None:
        if threading.current_thread() is self._turn_thread:
            self.call_from_thread(self._handle_event, event)
        else:
            self._handle_event(event)

    # ── periodic tick ────────────────────────────────────────────────────

    def _tick(self) -> None:
        if self._live_active:
            self._spinner_idx = (self._spinner_idx + 1) % len(SPINNER_FRAMES)
            if self._turn_start_time is not None:
                self._elapsed = time.monotonic() - self._turn_start_time
        self._render_progress()
        self._render_status()

    # ── rendering ────────────────────────────────────────────────────────

    def _render_progress(self) -> None:
        widget = self.query_one("#progress", Static)
        if self._live_active:
            frame = SPINNER_FRAMES[self._spinner_idx]
            secs = int(self._elapsed)
            itok = _fmt_tokens(self._turn_input_tokens)
            otok = _fmt_tokens(self._turn_output_tokens)
            widget.update(
                f"[cyan]{frame} {self._current_action}  "
                f"(iter {self._iteration}/{Agent.MAX_ITERATIONS} · {secs}s · "
                f"↑ {itok} · ↓ {otok} · {self._tool_call_count} calls)[/]"
            )
        else:
            used = _fmt_tokens(self._session_input_tokens)
            widget.update(f"[grey62]  \\[ready]   ctx {used}   {self._turn_count} turns[/]")

    def _render_status(self) -> None:
        widget = self.query_one("#status", Static)
        ver = self.repl.version or "?.?.?"
        model = self.repl.model or "(model)"
        used = _fmt_tokens(self._session_input_tokens)
        tools = self.context.tool_count
        clock = datetime.now().strftime("%H:%M:%S")
        bar = f" boukensha v{ver} · {model}  ·  ctx {used}  ·  {tools} tools  ·  {clock} "
        widget.update(bar)

    # ── input handling ───────────────────────────────────────────────────

    def on_input_submitted(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        event.input.value = ""
        if not text:
            return

        if text.startswith("/"):
            result = self.repl.handle_command(text)
            if result == "quit":
                self.exit()
                return
            if text == "/clear":
                self._turn_count = 0
                self._render_status()
            return

        self._write_line(f"> {text}")
        self._launch_turn(text)

    # ── agent thread ─────────────────────────────────────────────────────

    def _launch_turn(self, text: str) -> None:
        self._live_active = True
        self._spinner_idx = 0
        self._turn_start_time = time.monotonic()
        self._elapsed = 0.0
        self._current_action = "Thinking…"
        self._iteration = 0
        self._tool_call_count = 0
        self._turn_input_tokens = 0
        self._turn_output_tokens = 0
        self._render_progress()

        self._turn_thread = threading.Thread(target=self._do_turn, args=(text,), daemon=True)
        self._turn_thread.start()

    def _do_turn(self, text: str) -> None:
        try:
            self.repl.run_turn(text)
        except KeyboardInterrupt:
            self.call_from_thread(self._handle_event, {"phase": "turn_interrupted"})
        except Exception as e:  # noqa: BLE001 - mirrors Ruby's `rescue => e`
            self.call_from_thread(self._handle_event, {"phase": "turn_error", "error": str(e)})
        finally:
            self.call_from_thread(self._handle_event, {"phase": "turn_complete"})

    # ── event handling ───────────────────────────────────────────────────

    def _handle_event(self, event: dict) -> None:
        phase = str(event.get("phase") or "")

        if phase == "iteration":
            self._iteration = int(event.get("n") or 0)
            self._current_action = "Thinking…"
        elif phase == "tool_call":
            self._current_action = f"Calling tool: {event.get('name')}"
            self._tool_call_count += 1
        elif phase == "tool_result":
            self._current_action = "Awaiting result…"
        elif phase == "response":
            usage = event.get("usage")
            if usage:
                itu = int(usage.get("input_tokens") or 0)
                otu = int(usage.get("output_tokens") or 0)
                self._turn_input_tokens += itu
                self._turn_output_tokens += otu
                self._session_input_tokens += itu
                self._session_output_tokens += otu
        elif phase == "turn_complete":
            self._live_active = False
            self._turn_count += 1
        elif phase == "turn_interrupted":
            self._write_line("[interrupted]")
        elif phase == "turn_error":
            self._live_active = False
            self._write_line(f"[error] {event.get('error')}")

        self._render_progress()
        self._render_status()

    # ── keyboard actions ─────────────────────────────────────────────────

    def action_interrupt_turn(self) -> None:
        if self._turn_thread is not None and self._turn_thread.is_alive():
            _async_raise(self._turn_thread.ident, KeyboardInterrupt)

    def action_clear_history(self) -> None:
        self.repl.handle_command("/clear")
        self._turn_count = 0
        self._render_status()

    def action_scroll_up(self) -> None:
        self.query_one("#viewport", RichLog).scroll_page_up()

    def action_scroll_down(self) -> None:
        self.query_one("#viewport", RichLog).scroll_page_down()
