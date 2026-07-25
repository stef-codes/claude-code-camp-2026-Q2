from __future__ import annotations

import os
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# The MCP tests need a real MCP server to spawn. The mud-manager daemon in
# the week0_explore package is the one we have, so it plays the role of
# "some MCP server" — the code under test knows nothing about it beyond
# command/args/env.
MUD_MANAGER_ROOT = Path(__file__).resolve().parents[4] / "week0_explore" / "mud_manager"
MUD_MANAGER_BIN = MUD_MANAGER_ROOT / "bin" / "mud-manager"
MUD_MANAGER_LIB = MUD_MANAGER_ROOT / "lib"


def mud_manager_available() -> bool:
    return MUD_MANAGER_BIN.exists()


skip_without_mud_manager = pytest.mark.skipif(
    not mud_manager_available(), reason=f"mud_manager not found at {MUD_MANAGER_ROOT}"
)


def mud_manager_command() -> str:
    import shutil

    return shutil.which("ruby") or "ruby"


def mud_manager_args() -> list[str]:
    return [str(MUD_MANAGER_BIN), "--mcp"]


# Build a Config from a settings.yaml written into a throwaway BOUKENSHA_DIR.
@contextmanager
def config_from(yaml_text: str):
    from boukensha import Config

    with tempfile.TemporaryDirectory() as tmp_dir:
        Path(tmp_dir, "settings.yaml").write_text(yaml_text)
        old = os.environ.get("BOUKENSHA_DIR")
        os.environ["BOUKENSHA_DIR"] = tmp_dir
        try:
            yield Config()
        finally:
            if old is None:
                os.environ.pop("BOUKENSHA_DIR", None)
            else:
                os.environ["BOUKENSHA_DIR"] = old
