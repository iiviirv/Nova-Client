#!/usr/bin/env bash
# Extract one version's section from CHANGELOG.md into release notes.
# Usage: tool/release_notes.sh <tag> [changelog] > notes.md
# The tag (e.g. "v1.2.0-beta") is matched against a "## <tag> ..." heading.
# Falls back to a short generic note if the section isn't found, so a release
# never ends up with an empty body.
set -euo pipefail

tag="${1:?usage: release_notes.sh <tag> [changelog]}"
changelog="${2:-CHANGELOG.md}"

if [[ -f "$changelog" ]]; then
  # Print lines from the heading that starts with "## <tag>" up to (but not
  # including) the next "## " heading. awk with an exact prefix match on the
  # heading avoids partial-version collisions.
  section="$(awk -v tag="$tag" '
    $0 ~ "^## " tag "([ (]|$)" { grab=1; print; next }
    grab && /^## / { exit }
    grab { print }
  ' "$changelog")"
else
  section=""
fi

if [[ -n "${section// /}" ]]; then
  printf '%s\n' "$section"
else
  printf '## %s\n\nNova Client %s. See the full changelog at https://github.com/IRNova/Nova-Client/blob/main/CHANGELOG.md\n' "$tag" "$tag"
fi
