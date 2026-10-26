#!/usr/bin/env bash
# Prints the source identity of the checkout: `<HEAD>` when clean, or
# `<HEAD>-dirty-<12 hex>` hashing tracked diffs plus untracked, non-ignored
# files (NookKit and synchronized groups compile files git does not track).
# make perf-build stamps it into the app; run.sh refuses a mismatch.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$repo_root"
export LC_ALL=C

head="$(git rev-parse HEAD)"
# Separate assignments so set -e sees a git failure; --untracked-files=all
# overrides a status.showUntrackedFiles=no config that would hide new sources.
porcelain="$(git status --porcelain --untracked-files=all)"
if [[ -z "$porcelain" ]]; then
  echo "$head"
  exit 0
fi

tracked_diff="$(git diff HEAD --binary)"
fingerprint="$(
  {
    printf '%s\0' "$tracked_diff"
    git ls-files -o --exclude-standard -z | while IFS= read -r -d '' path; do
      printf 'untracked %s\0' "$path"
      if [[ -L "$path" ]]; then
        printf 'symlink %s\0' "$(readlink "$path")"
      elif [[ -f "$path" ]]; then
        cat -- "$path"
        printf '\0'
      fi
    done
  } | shasum -a 256 | cut -c1-12
)"
echo "$head-dirty-$fingerprint"
