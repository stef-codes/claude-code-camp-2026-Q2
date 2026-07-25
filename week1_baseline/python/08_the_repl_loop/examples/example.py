from __future__ import annotations

import os
from pathlib import Path

import boukensha

# Config is loaded automatically inside boukensha.repl — system prompt,
# model, and API key all come from ~/.boukensha (or BOUKENSHA_DIR) by
# default. Unlike earlier steps, this example does NOT override
# BOUKENSHA_DIR: Config's directory resolution now also checks for a
# .boukensha/ directory in the current working directory, so running this
# from the repo root picks it up automatically — matching the upstream
# Ruby example's design for this step.

print(f"Config: {boukensha.config()}")
print()

# The base directory tools will operate relative to — the step 7 folder
# makes a good playground since it already has source files to read.
base_dir = Path(__file__).resolve().parent.parent.parent / "07_the_run_dsl"


def register(dsl: boukensha.RunDSL) -> None:
    dsl.tool(
        "read_file",
        description="Read the contents of a file from disk",
        parameters={
            "path": {"type": "string", "description": "File path (relative to the working directory)"}
        },
        block=lambda path: (base_dir / path).read_text(),
    )

    dsl.tool(
        "list_directory",
        description="List the files in a directory",
        parameters={
            "path": {
                "type": "string",
                "description": "Directory path (relative to the working directory, or '.' for root)",
            }
        },
        block=lambda path: ", ".join(
            sorted(f for f in os.listdir(base_dir / path) if not f.startswith("."))
        ),
    )


boukensha.repl(register=register)
