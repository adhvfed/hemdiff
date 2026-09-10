#!/bin/bash
# Install an already built executable. Does not configure roots or permissions.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source_binary=${1:-"$repo/build/agent/hemdiff"}
prefix=${2:-"$HOME/.local"}
if [[ ! -f "$source_binary" || ! -x "$source_binary" ]]; then
  echo "Build the executable first with tools/build-agent.sh." >&2
  exit 1
fi
mkdir -p "$prefix/bin"
temporary=$(mktemp "$prefix/bin/.hemdiff-install.XXXXXX")
trap 'rm -f "$temporary"' EXIT
install -m 755 "$source_binary" "$temporary"
mv -f "$temporary" "$prefix/bin/hemdiff"
printf 'Installed %s\n' "$prefix/bin/hemdiff"
