from __future__ import annotations

import os
from pathlib import Path

import pytest

import boukensha_loader


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("BOUKENSHA_PATH", raising=False)
    monkeypatch.delenv("BOUKENSHA_DIR", raising=False)
    return tmp_path


def make_step(home: Path, name: str) -> Path:
    step = home / name
    (step / "boukensha").mkdir(parents=True)
    (step / "boukensha" / "__init__.py").touch()
    return step


def write_rc(home: Path, contents: str) -> None:
    (home / ".boukensharc").write_text(contents)


def test_yaml_configures_implementation_and_runtime_directory(home):
    step = make_step(home, "configured-step")
    write_rc(home, f"boukensha_path: {step}\nboukensha_dir: config\n")

    assert boukensha_loader.resolve() == str(step / "boukensha" / "__init__.py")
    assert os.environ["BOUKENSHA_DIR"] == str(home / "config")


def test_environment_variables_override_rc_values(home, monkeypatch):
    rc_step = make_step(home, "rc-step")
    env_step = make_step(home, "env-step")
    write_rc(home, f"boukensha_path: {rc_step}\nboukensha_dir: rc-config\n")
    monkeypatch.setenv("BOUKENSHA_PATH", str(env_step))
    monkeypatch.setenv("BOUKENSHA_DIR", "/explicit/config")

    assert boukensha_loader.resolve() == str(env_step / "boukensha" / "__init__.py")
    assert os.environ["BOUKENSHA_DIR"] == "/explicit/config"


def test_legacy_single_path_format_is_supported(home):
    step = make_step(home, "legacy-step")
    write_rc(home, f"{step}\n")

    assert boukensha_loader.resolve() == str(step / "boukensha" / "__init__.py")


def test_empty_config_uses_bundled_implementation(home):
    write_rc(home, "")

    assert boukensha_loader.resolve() == boukensha_loader.BUNDLED_MAIN
