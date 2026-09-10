#!/bin/bash
# Build the host executable, or pass --swift-sdk for a cross-compiled executable.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
configuration=release
output="$repo/build/agent"
sdk=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration=debug; shift ;;
    --output) output=${2:?Missing output directory}; shift 2 ;;
    --swift-sdk) sdk=${2:?Missing Swift SDK identifier}; shift 2 ;;
    *) echo "Usage: $0 [--debug] [--output DIRECTORY] [--swift-sdk IDENTIFIER]" >&2; exit 2 ;;
  esac
done
args=(--package-path "$repo/Packages/HemdiffAgent" --configuration "$configuration" --jobs "${HEMDIFF_BUILD_JOBS:-4}")
if [[ -n "$sdk" ]]; then args+=(--swift-sdk "$sdk"); fi
swift build "${args[@]}" --product hemdiff
bin=$(swift build "${args[@]}" --show-bin-path)
mkdir -p "$output"
install -m 755 "$bin/hemdiff" "$output/hemdiff"
if [[ -f "$repo/docs/agent-access.md" ]]; then cp "$repo/docs/agent-access.md" "$output/README.md"; fi
# Static Swift SDKs include debug information even in release archives.
if [[ "$(uname -s)" == Linux ]] && command -v strip >/dev/null 2>&1; then
  strip --strip-debug "$output/hemdiff"
fi
"$repo/tools/copy-package-notices.sh" "$repo/Packages/HemdiffAgent/.build/checkouts" "$output/third-party-licenses"
cp -R "$repo/Packages/HemdiffCore/Notices" "$output/third-party-licenses/linux-uapi"
printf 'Built %s\n' "$output/hemdiff"
