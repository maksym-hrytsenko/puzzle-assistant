#!/usr/bin/env bash
# One-command launcher: creates a virtualenv, installs dependencies, runs the test.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
venv="$root/.venv"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
fi
"$venv/bin/pip" install -q -r "$here/requirements.txt"
exec "$venv/bin/python" "$here/puzzle_match.py" "$@"
