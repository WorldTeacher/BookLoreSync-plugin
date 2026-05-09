#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
cd "$REPO_ROOT"

OUTPUT_FILE="${1:-CHANGELOG.pregen.md}"
EXISTING_CHANGELOG="${EXISTING_CHANGELOG_FILE:-CHANGELOG.md}"

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: this script must run inside a git repository" >&2
    exit 1
fi

latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
log_range="HEAD"
if [ -n "$latest_tag" ]; then
    log_range="${latest_tag}..HEAD"
fi

has_release_commit=0
bump_level="none"

features=()
bug_fixes=()
perf_improvements=()
reverts=()
breaking_changes=()

origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
repo_url=""
if [[ "$origin_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
    repo_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$origin_url" =~ ^git@([^:]+):(.+)$ ]]; then
    repo_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$origin_url" =~ ^https?://.+$ ]]; then
    repo_url="${origin_url%.git}"
fi

append_line() {
    local commit_hash="$1"
    local scope="$2"
    local description="$3"

    local short_hash
    short_hash="$(git rev-parse --short "$commit_hash")"

    local commit_ref="${short_hash}"
    if [ -n "$repo_url" ]; then
        commit_ref="[${short_hash}](${repo_url}/commit/${commit_hash})"
    fi

    if [ -n "$scope" ]; then
        printf '* **%s:** %s (%s)' "$scope" "$description" "$commit_ref"
    else
        printf '* %s (%s)' "$description" "$commit_ref"
    fi
}

contains_breaking_change_note() {
    local body="$1"
    if [[ "$body" == *"BREAKING CHANGE:"* ]] || [[ "$body" == *"BREAKING-CHANGE:"* ]]; then
        return 0
    fi
    return 1
}

while IFS= read -r -d $'\x1e' entry; do
    [ -z "$entry" ] && continue

    entry="${entry#$'\n'}"

    commit_hash="${entry%%$'\x1f'*}"
    rest="${entry#*$'\x1f'}"
    subject="${rest%%$'\x1f'*}"
    body="${rest#*$'\x1f'}"

    if [[ "$subject" =~ ^([a-zA-Z]+)(\(([[:alnum:]_./-]+)\))?(!)?:[[:space:]](.+)$ ]]; then
        commit_type="${BASH_REMATCH[1],,}"
        scope="${BASH_REMATCH[3]:-}"
        is_breaking="${BASH_REMATCH[4]:-}"
        description="${BASH_REMATCH[5]}"

        case "$commit_type" in
            feat)
                features+=("$(append_line "$commit_hash" "$scope" "$description")")
                has_release_commit=1
                if [ "$bump_level" != "major" ] && [ "$bump_level" != "minor" ]; then
                    bump_level="minor"
                fi
                ;;
            fix)
                bug_fixes+=("$(append_line "$commit_hash" "$scope" "$description")")
                has_release_commit=1
                if [ "$bump_level" = "none" ]; then
                    bump_level="patch"
                fi
                ;;
            perf)
                perf_improvements+=("$(append_line "$commit_hash" "$scope" "$description")")
                has_release_commit=1
                if [ "$bump_level" = "none" ]; then
                    bump_level="patch"
                fi
                ;;
            revert)
                reverts+=("$(append_line "$commit_hash" "$scope" "$description")")
                has_release_commit=1
                if [ "$bump_level" = "none" ]; then
                    bump_level="patch"
                fi
                ;;
            *)
                ;;
        esac

        if [ -n "$is_breaking" ] || contains_breaking_change_note "$body"; then
            breaking_changes+=("$(append_line "$commit_hash" "$scope" "$description")")
            has_release_commit=1
            bump_level="major"
        fi
    fi
done < <(git log --reverse --pretty=tformat:'%H%x1f%s%x1f%b%x1e' "$log_range")

compute_next_version() {
    local current_tag="$1"
    local level="$2"

    local major=0
    local minor=0
    local patch=0

    if [ -n "$current_tag" ] && [[ "$current_tag" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
    fi

    case "$level" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        none)
            ;;
    esac

    printf '%s.%s.%s' "$major" "$minor" "$patch"
}

next_version="$(compute_next_version "$latest_tag" "$bump_level")"
release_date="$(date -u +%Y-%m-%d)"

if [ "$has_release_commit" -eq 0 ]; then
    compare_hint="HEAD"
    if [ -n "$latest_tag" ]; then
        compare_hint="$latest_tag"
    fi

    {
        printf '# Changelog pre-generation\n\n'
        printf 'No release-worthy Conventional Commit entries found since `%s`.\n\n' "$compare_hint"
        printf 'Expected commit types: `feat`, `fix`, `perf`, `revert`, and breaking changes (`!` or `BREAKING CHANGE:`).\n'
    } > "$OUTPUT_FILE"

    echo "Created $OUTPUT_FILE (no releasable changes detected)."
    exit 0
fi

{
    if [ -n "$latest_tag" ] && [ -n "$repo_url" ]; then
        printf '## [%s](%s/compare/%s...%s) (%s)\n\n' "$next_version" "$repo_url" "$latest_tag" "$next_version" "$release_date"
    elif [ -n "$latest_tag" ]; then
        printf '## %s (%s)\n\n' "$next_version" "$release_date"
    else
        printf '# %s (%s)\n\n' "$next_version" "$release_date"
    fi

    if [ "${#bug_fixes[@]}" -gt 0 ]; then
        printf '### Bug Fixes\n\n'
        printf '%s\n' "${bug_fixes[@]}"
        printf '\n'
    fi

    if [ "${#features[@]}" -gt 0 ]; then
        printf '### Features\n\n'
        printf '%s\n' "${features[@]}"
        printf '\n'
    fi

    if [ "${#perf_improvements[@]}" -gt 0 ]; then
        printf '### Performance Improvements\n\n'
        printf '%s\n' "${perf_improvements[@]}"
        printf '\n'
    fi

    if [ "${#reverts[@]}" -gt 0 ]; then
        printf '### Reverts\n\n'
        printf '%s\n' "${reverts[@]}"
        printf '\n'
    fi

    if [ "${#breaking_changes[@]}" -gt 0 ]; then
        printf '### BREAKING CHANGES\n\n'
        printf '%s\n' "${breaking_changes[@]}"
        printf '\n'
    fi

    if [ -f "$EXISTING_CHANGELOG" ]; then
        cat "$EXISTING_CHANGELOG"
    fi
} > "$OUTPUT_FILE"

echo "Created $OUTPUT_FILE"
if [ -n "$latest_tag" ]; then
    echo "Based on commits in range: $latest_tag..HEAD"
else
    echo "Based on all commits (no existing tag found)"
fi
echo "Predicted next version: $next_version"
