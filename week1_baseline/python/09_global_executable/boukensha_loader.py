"""
BoukenshaLoader resolves which step folder and config directory to use, then
boots the REPL.

Each setting is resolved independently in this order:
  1. BOUKENSHA_PATH / BOUKENSHA_DIR environment variable
  2. boukensha_path / boukensha_dir in ~/.boukensharc
  3. The bundled package / ~/.boukensha default

Examples:
  boukensha                                                          # uses bundled package + ~/.boukensha
  BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha            # loads step 4
  BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                 # custom config dir
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml

# Absolute path to this package's own bundled boukensha/__init__.py.
BUNDLED_MAIN = str(Path(__file__).resolve().parent / "boukensha" / "__init__.py")


def rc_file() -> Path:
    return Path("~/.boukensharc").expanduser()


def load_rc() -> dict:
    path = rc_file()
    if not path.exists():
        return {}

    try:
        parsed = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        sys.exit(f"boukensha: invalid YAML in {path}: {e}")

    if isinstance(parsed, dict):
        return parsed
    if isinstance(parsed, str):
        # Backward compatibility with the original single-path format.
        return {"boukensha_path": parsed}
    if parsed is None:
        return {}
    sys.exit(f"boukensha: {path} must contain a YAML mapping")


def expand_rc_path(path) -> str | None:
    if not isinstance(path, str) or not path.strip():
        return None

    p = Path(path).expanduser()
    if not p.is_absolute():
        p = rc_file().parent / p
    return str(p.resolve())


def resolve() -> str:
    rc = load_rc()

    # Apply this before importing the selected implementation. An explicit
    # environment variable always wins over the rc file.
    rc_config_dir = expand_rc_path(rc.get("boukensha_dir"))
    if not os.environ.get("BOUKENSHA_DIR") and rc_config_dir:
        os.environ["BOUKENSHA_DIR"] = rc_config_dir

    source = os.environ.get("BOUKENSHA_PATH") or expand_rc_path(rc.get("boukensha_path"))
    if not source:
        return BUNDLED_MAIN

    step_dir = str(Path(source).expanduser().resolve())
    main = Path(step_dir) / "boukensha" / "__init__.py"
    if main.exists():
        return str(main)

    sys.exit(
        f"boukensha: no boukensha/__init__.py found at:\n"
        f"       {step_dir}\n"
        f"       Check BOUKENSHA_PATH or {rc_file()}."
    )


def load_and_start_repl() -> None:
    main = resolve()
    step_dir = str(Path(main).parent.parent)

    if os.environ.get("BOUKENSHA_DEBUG"):
        print(f"[boukensha] loading from: {step_dir}")

    if main != BUNDLED_MAIN:
        # Load a different step's boukensha package dynamically — drop any
        # cached "boukensha" module (this package's own) and import the one
        # found at step_dir instead.
        sys.path.insert(0, step_dir)
        for name in list(sys.modules):
            if name == "boukensha" or name.startswith("boukensha."):
                del sys.modules[name]

    import boukensha as impl

    if not hasattr(impl, "repl"):
        sys.exit(
            f"boukensha: the step at {step_dir}\n"
            f"       does not support the interactive REPL (added in step 7).\n"
            f"       Run its examples directly, e.g.:\n"
            f"         python {step_dir}/examples/*.py\n"
            f"       Or point BOUKENSHA_PATH at step 7 or later."
        )

    impl.repl()


def main() -> None:
    load_and_start_repl()
