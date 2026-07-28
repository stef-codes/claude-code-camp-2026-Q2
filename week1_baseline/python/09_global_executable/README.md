# 09 · Global Executable (Python port)

Python port of [`ruby/09_global_executable`](../../ruby/09_global_executable/README.md).
Built on top of the [`08_the_repl_loop`](../08_the_repl_loop/README.md) port.

Package BOUKENSHA so the `boukensha` command works from anywhere on your
machine, the same way Ruby packages it as a gem with a `bin/boukensha`
executable.

## What this step adds

- `pyproject.toml`'s `[project.scripts]` — declares `boukensha = "boukensha_loader:main"`, an installable console-script entry point
- `bin/boukensha` — a thin shim so the executable also runs straight out of a step directory without installing, matching Ruby's `bin/boukensha`
- `boukensha_loader.py` — resolves the step folder and runtime config directory, then boots the REPL
- `boukensha/` — this step's library, bundled as the default implementation
- `test/test_boukensha_loader.py` — first `pytest` suite in the port series (see "Differences from Ruby")

## Install

```bash
uv tool install ./week1_baseline/python/09_global_executable          # pinned snapshot
# or, so the command tracks your live source (recommended while developing):
uv tool install --editable ./week1_baseline/python/09_global_executable
```

`uv tool install` drops the `boukensha` executable in uv's tool bin
directory (`uv tool dir --bin`, usually `~/.local/bin`). If that directory
isn't on your `$PATH`, the command will still be "not found" — run
`uv tool update-shell` once and restart your shell to fix that. After that,
`boukensha` works from any directory. Or, without installing, run it
directly via `uv run`:

```bash
uv run --project week1_baseline/python/09_global_executable boukensha
```

> In this repo the runtime config lives at the **repo-root** `.boukensha/`,
> not `~/.boukensha`. Point the installed command at it with a one-time
> `~/.boukensharc` (`boukensha_dir: /abs/path/to/repo/.boukensha`) or a
> per-run `BOUKENSHA_DIR=...`, otherwise you'll hit
> `tasks.player.model is required`. See `boukensha_dir` below.

## Configuring the global executable

`~/.boukensharc` is a YAML file that can configure both the implementation
to load and the directory containing `.env`, `settings.yaml`, and `prompts/`:

```yaml
boukensha_path: ~/Sites/boukensha/python/08_the_repl_loop
boukensha_dir: ~/Sites/boukensha/.boukensha
```

Each value is resolved independently:

| Setting | First priority | Second priority | Default |
|---------|-----------------|-------------------|---------|
| Implementation | `BOUKENSHA_PATH` | `boukensha_path` in `~/.boukensharc` | Bundled implementation |
| Runtime config | `BOUKENSHA_DIR` | `boukensha_dir` in `~/.boukensharc` | `~/.boukensha` |

`BOUKENSHA_PATH` must point to a step folder that contains `boukensha/__init__.py`.
The original single-path `.boukensharc` format (a bare string) is still
accepted and treated as `boukensha_path`.

## Running a specific step

```bash
# step 8 (interactive REPL)
BOUKENSHA_PATH=~/Sites/boukensha/python/08_the_repl_loop boukensha

# step 7 doesn't have a REPL — loader tells you how to run it
BOUKENSHA_PATH=~/Sites/boukensha/python/07_the_run_dsl boukensha
# => boukensha: the step at .../07_the_run_dsl does not support the interactive REPL
#    Run its examples directly, e.g.: python .../07_the_run_dsl/examples/*.py
```

## Debug mode

```bash
BOUKENSHA_DEBUG=1 boukensha
# => [boukensha] loading from: /path/to/step
```

## Tests

```bash
uv run pytest
```

## The key idea

The package is just a **wrapper and a default**. All the teaching material
stays in the numbered step folders exactly as it was — the loader doesn't
copy or symlink anything, it just knows where to look.

## Differences from Ruby

- **First `pytest` suite in the Python port series.** Every earlier step
  followed a "no pytest" policy (matching Ruby, which had none either). This
  step is a deliberate, explicit exception: upstream Ruby itself added a
  test suite for exactly the loader/rc-resolution logic ported here
  (`test/test_boukensha_loader.rb`), so the Python port adds the matching
  `test/test_boukensha_loader.py`.
- **`uv tool install .` / `[project.scripts]`** is the Python equivalent of
  `gem build` + `gem install` — both produce a `boukensha` executable on
  `$PATH` backed by the same source tree.
- Carries forward the standing decisions from earlier steps: `.yaml`/`.yml`
  fallback fix (Python-side only), `uv`/hatchling, `requires-python >=3.14`.
