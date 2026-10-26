#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Brings the custom branch up to the newest stable upstream release, then tests
# it and installs it as Vorssaint (Developer). The Developer variant never
# updates itself, so a release can't replace the custom changes.
#
# A merge conflict stops the script. Resolve it, run `git commit`, then run the
# script again: the build compares its stamped commit with HEAD, so a merged
# but uninstalled release is still built.

set -euo pipefail
cd "${0:A:h}/.."

branch=custom
app="/Applications/Vorssaint (Developer).app"

[[ "$(git branch --show-current)" == "$branch" ]] || { echo "Switch to the $branch branch first." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }

git fetch --tags upstream
tag="$(git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"

if ! git merge-base --is-ancestor "$tag" HEAD; then
    git merge --no-edit -m "Merge upstream $tag" "$tag" || {
        echo "Resolve the conflicts, run 'git commit', then run this script again." >&2
        exit 1
    }
fi

installed="$(/usr/libexec/PlistBuddy -c 'Print :VorssaintBuildCommit' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$installed" == "$(git rev-parse --short HEAD) "* ]]; then
    echo "Up to date: $tag is merged and installed."
    exit 0
fi

# ponytail: one retry, because upstream's NotchCompactTests rail check fails
# about half the time on v3.4.2 as released. A real failure fails twice.
./build.sh --test || ./build.sh --test
./build.sh --dev --install
