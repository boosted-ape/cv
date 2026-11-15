#!/usr/bin/env bash
# Regenerate the site into the repo root (GitHub Pages serves master root).
# Never pass --cleanDestinationDir here: the source tree lives in the output dir.
set -euo pipefail
cd "$(dirname "$0")"
exec hugo --minify
