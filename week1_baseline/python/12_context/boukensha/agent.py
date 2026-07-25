from __future__ import annotations

from .errors import ApiError
from .logger import Logger


class Agent:
    # Default iteration ceiling. The *enforced* value comes from the
    # max_iterations constructor arg (sourced from Config at the run/repl
    # path), which falls back to this constant. 0 (or None) disables the
    # ceiling.
    MAX_ITERATIONS = 25

    # The wind-down call is deliberately short and cheap.
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = (
        "You have reached your action limit for this turn. Do not call any more tools.\n"
        "Briefly summarize what you accomplished, what is still unfinished, and the\n"
        "single next action you would take."
    ).strip()

    def __init__(
        self,
        *,
        context,
        registry,
        builder,
        client,
        logger: Logger | None = None,
        max_iterations: int | None = MAX_ITERATIONS,
        max_turn_tokens: int | None = None,
        max_output_tokens: int | None = None,
    ) -> None:
        self.context = context
        self.registry = registry
        self.builder = builder
        self.client = client
        self.logger = logger if logger is not None else Logger()
        self.max_iterations = int(self.MAX_ITERATIONS if max_iterations is None else max_iterations)
        self.max_turn_tokens = int(max_turn_tokens or 0)  # 0 = disabled
        self.max_output_tokens = max_output_tokens
        self.iteration = 0

    def run(self) -> str:
        self.context.reset_turn_tokens()
        self._compact_if_needed()

        while True:
            # Two independent ceilings; stop at whichever trips first. Limits
            # are *trigger thresholds*, not hard caps: when one is reached we
            # stop starting new work iterations and make exactly one terminal
            # wind-down call (counted in tokens, but not as another
            # iteration).
            if self._iteration_limit_reached():
                self.logger.limit_reached(
                    kind="max_iterations", n=self.iteration, max=self.max_iterations
                )
                return self._wrap_up("max_iterations")
            if self._token_limit_reached():
                self.logger.limit_reached(
                    kind="max_tokens", n=self.context.turn_tokens, max=self.max_turn_tokens
                )
                return self._wrap_up("max_tokens")

            self.iteration += 1
            self.logger.iteration(n=self.iteration, max=self.max_iterations)
            self.logger.prompt(
                messages=self.context.messages,
                tools=self.context.tools,
                context_window=self.context.context_window,
            )

            response = self.client.call(**self._call_opts())
            self.logger.raw(data=response)
            parsed = self.builder.parse_response(response)
            self._record_usage(response)
            self._log_reasoning(parsed["content"])

            if parsed["stop_reason"] == "tool_use":
                self._handle_tool_calls(parsed["content"], response)
            else:
                text = self._extract_text(parsed["content"])
                self.logger.response(
                    text=text,
                    usage=response.get("usage"),
                    stop_reason=parsed["stop_reason"],
                    task=None,
                    backend=self.builder.backend,
                )
                self.logger.turn_end(
                    reason="completed", iterations=self.iteration, tokens=self.context.turn_tokens
                )
                self.context.add_message("assistant", text)
                return text

    def _iteration_limit_reached(self) -> bool:
        return self.max_iterations > 0 and self.iteration >= self.max_iterations

    def _token_limit_reached(self) -> bool:
        return self.max_turn_tokens > 0 and self.context.turn_tokens >= self.max_turn_tokens

    # Per-call options shared by every model round-trip of the turn.
    def _call_opts(self) -> dict:
        if self.max_output_tokens is not None:
            return {"max_output_tokens": self.max_output_tokens}
        return {}

    # Add this call's input+output to the cumulative turn total (the spend
    # budget) and refresh the known context size from input_tokens
    # (compaction pressure). The trigger is evaluated on pre-wrap-up spend;
    # the reported total includes the wind-down call too.
    def _record_usage(self, response: dict) -> None:
        usage = response.get("usage") or {}
        self.context.add_turn_tokens(usage.get("input_tokens"), usage.get("output_tokens"))
        self.context.update_tokens(usage.get("input_tokens"))

    def _compact_if_needed(self) -> None:
        if not self.context.needs_compaction():
            return

        before = self.context.current_tokens
        dropped = self.context.compact_messages()
        self.logger.compaction(before=before, dropped=dropped, context_window=self.context.context_window)

    # One final, tools-disabled model call so the agent ends the turn in
    # character rather than aborting. Runs *outside* the counted loop: it
    # never re-checks the limits (so it cannot re-trigger) and does not
    # increment self.iteration, though its tokens still count toward the
    # reported turn total. Falls back to a deterministic message if the call
    # fails.
    def _wrap_up(self, reason: str) -> str:
        self.context.add_message("user", self.WRAP_UP_DIRECTIVE)
        try:
            response = self.client.call(tools=[], max_output_tokens=self.WRAP_UP_OUTPUT_TOKENS)
            parsed_wrap = self.builder.parse_response(response)
            text = self._extract_text(parsed_wrap["content"])
            if not text.strip():
                text = self._fallback_message(reason)
            self._record_usage(response)
            self.logger.response(
                text=text,
                usage=response.get("usage"),
                stop_reason=parsed_wrap["stop_reason"],
                task=None,
                backend=self.builder.backend,
            )
            self.logger.turn_end(reason=reason, iterations=self.iteration, tokens=self.context.turn_tokens)
            self.context.add_message("assistant", text)
            return text
        except ApiError:
            msg = self._fallback_message(reason)
            self.logger.turn_end(reason=reason, iterations=self.iteration, tokens=self.context.turn_tokens)
            self.context.add_message("assistant", msg)
            return msg

    def _fallback_message(self, reason: str) -> str:
        return (
            f"I reached my {self.max_iterations}-action limit for this turn before finishing "
            f"({reason}). Ask me to continue and I'll pick up from here."
        )

    def _extract_text(self, content: list[dict]) -> str:
        return "\n".join(b["text"] for b in content if b.get("type") == "text")

    # Emit one `reasoning` event per reasoning block so the viewer can show
    # the model's thinking as a first-class step. Empty, non-redacted blocks
    # are skipped to avoid noise (a redacted/omitted block still renders,
    # since it tells the viewer "the model thought here").
    def _log_reasoning(self, content: list[dict]) -> None:
        for block in content:
            if block.get("type") != "reasoning":
                continue
            redacted = block.get("redacted") is True
            text = str(block.get("text") or "")
            if not text.strip() and not redacted:
                continue
            self.logger.reasoning(text=text, redacted=redacted)

    def _handle_tool_calls(self, content: list[dict], response: dict) -> None:
        tool_calls = [b for b in content if b.get("type") == "tool_use"]

        # Log any preamble text that accompanied the tool call (carries no
        # usage — the placeholder below owns the turn's usage chip), then the
        # placeholder.
        preamble = self._extract_text(content)
        if preamble.strip():
            self.logger.plan(text=preamble)
        plural = "s" if len(tool_calls) != 1 else ""
        self.logger.response(
            text=f"(tool use — {len(tool_calls)} call{plural})",
            usage=response.get("usage"),
            stop_reason="tool_use",
        )

        self.context.add_message("assistant", content)

        for block in tool_calls:
            name = block.get("name")
            args = block.get("input")
            use_id = block.get("id")

            self.logger.tool_call(name=name, args=args)
            try:
                result = self.registry.dispatch(name, args)
                self.logger.tool_result(name=name, result=result, ok=True)
            except Exception as e:
                result = f"ERROR: {type(e).__name__}: {e}"
                self.logger.tool_result(name=name, result=result, ok=False, error=str(e))

            self.context.add_message("tool_result", str(result), tool_use_id=use_id)
