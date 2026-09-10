#!/bin/bash
# Preserve top-level and vendored dependency notices in distributable bundles.
set -euo pipefail
checkouts=${1:?Missing checkout directory}
output=${2:?Missing output directory}
[[ -d "$checkouts" ]] || { echo "Missing resolved package checkouts: $checkouts" >&2; exit 1; }
mkdir -p "$output"
for checkout in "$checkouts/"*; do
  [[ -d "$checkout" ]] || continue
  while IFS= read -r -d '' notice; do
    relative=${notice#"$checkout/"}
    destination="$output/$(basename "$checkout")/$relative"
    mkdir -p "$(dirname "$destination")"
    cp "$notice" "$destination"
  done < <(find "$checkout" -type f \( -name 'LICENSE*' -o -name 'NOTICE*' -o -name 'COPYING*' \) -print0)
done
