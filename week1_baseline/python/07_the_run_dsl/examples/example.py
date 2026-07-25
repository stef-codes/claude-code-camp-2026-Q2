from __future__ import annotations

import os
from pathlib import Path

import boukensha

# Override the config directory so the example works from the repo root.
# In real usage a user's ~/.boukensha is picked up automatically.
#
# NOTE: the upstream Ruby example for this step has an off-by-one in this
# same fallback path (../../../.boukensha, one level too shallow) which
# actually breaks the demo when BOUKENSHA_DIR isn't already set — this port
# uses the correct depth instead of replicating that bug.
os.environ.setdefault(
    "BOUKENSHA_DIR",
    str((Path(__file__).resolve().parent / "../../../../.boukensha").resolve()),
)

# Config is loaded automatically inside boukensha.run — system prompt, model,
# and API key all come from ~/.boukensha (or BOUKENSHA_DIR) by default.
# You can still override any of them as keyword arguments if you want.

print("=== BOUKENSHA Step 7: The boukensha.run DSL ===")
print()
print(f"Config: {boukensha.config()}")
print()

base_dir = Path(__file__).resolve().parent.parent


def register(dsl: boukensha.RunDSL) -> None:
    dsl.tool(
        "read_file",
        description="Read the contents of a file from disk",
        parameters={"path": {"type": "string", "description": "The file path to read"}},
        block=lambda path: (base_dir / path).read_text(),
    )

    dsl.tool(
        "list_directory",
        description="List the files in a directory",
        parameters={"path": {"type": "string", "description": "The directory path to list"}},
        block=lambda path: ", ".join(
            f for f in os.listdir(base_dir / path) if not f.startswith(".")
        ),
    )


result = boukensha.run(
    task="Read the README.md file and summarise what this MUD player assistant framework can do.",
    register=register,
)

print()
print("=== FINAL RESPONSE ===")
print(result)
