set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
cd "$REPO_ROOT"

OUTPUT_FILE="CHANGELOG.pregen.md"
DOCS_MODE=0
CHANGELOG_SOURCE="CHANGELOG.md"
DOCS_CHANGELOG_FILE="docs/content/reference/changelog.md"

usage() {
    cat <<'EOF'
Usage:
  scripts/changelog-pregen.sh [output-file]
  scripts/changelog-pregen.sh --docs

Options:
  --docs   Update docs/content/reference/changelog.md from CHANGELOG.md
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --docs)
            DOCS_MODE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ "$DOCS_MODE" -eq 1 ]; then
                echo "ERROR: unexpected argument in --docs mode: $1" >&2
                usage
                exit 1
            fi
            OUTPUT_FILE="$1"
            shift
            ;;
    esac
done

EXISTING_CHANGELOG="${EXISTING_CHANGELOG_FILE:-CHANGELOG.md}"

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: this script must run inside a git repository" >&2
    exit 1
fi

update_docs_changelog() {
    local -a tag_names=()
    local -a tag_versions=()
    local tag

    declare -A seen_versions=()

    append_unique_changelog_line() {
        local array_name="$1"
        local seen_name="$2"
        local line="$3"

        local -n target_array="$array_name"
        local -n seen_map="$seen_name"

        if [ -n "${seen_map[$line]:-}" ]; then
            return 0
        fi

        seen_map[$line]=1
        target_array+=("$line")
    }

    while IFS=$'\t' read -r tag normalized_version; do
        [ -z "$tag" ] && continue
        [ -z "$normalized_version" ] && continue

        if [ -n "${seen_versions[$normalized_version]:-}" ]; then
            continue
        fi

        seen_versions[$normalized_version]=1
        tag_names+=("$tag")
        tag_versions+=("$normalized_version")
    done < <(
        git for-each-ref --format='%(refname:short)' refs/tags \
            | awk 'BEGIN { OFS="\t" } { v=$0; sub(/^v/, "", v); if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print $0, v }' \
            | sort -t $'\t' -k2,2Vr
    )

    if [ "${#tag_names[@]}" -eq 0 ]; then
        echo "ERROR: no semantic version tags found" >&2
        exit 1
    fi

    {
        printf '+++\n'
        printf 'title = "Changelog"\n'
        printf 'description = "Full version history for the BookLore Sync plugin."\n'
        printf 'weight = 4\n'
        printf '+++\n\n'
        printf '# Changelog\n\n'
        printf 'All notable changes to the BookLore Sync plugin are documented here.\n\n'
        printf '%s\n\n' '---'

        local latest_tag="${tag_names[0]}"
        local latest_version="${tag_versions[0]}"
        local upcoming_date
        upcoming_date="$(date -u +%Y-%m-%d)"

        local up_bump_level="none"
        local -a up_features=()
        local -a up_bug_fixes=()
        local -a up_perf_improvements=()
        local -a up_reverts=()
        local -a up_breaking_changes=()
        local -a up_maintenance=()
        local -a up_others=()

        declare -A up_seen_features=()
        declare -A up_seen_bug_fixes=()
        declare -A up_seen_perf_improvements=()
        declare -A up_seen_reverts=()
        declare -A up_seen_breaking_changes=()
        declare -A up_seen_maintenance=()
        declare -A up_seen_others=()

        while IFS= read -r -d $'\x1e' entry; do
            [ -z "$entry" ] && continue

            entry="${entry#$'\n'}"

            local subject="${entry%%$'\x1f'*}"
            local body="${entry#*$'\x1f'}"
            local subject_text="$subject"

            if [[ "$subject" =~ ^([a-zA-Z]+)(\(([[:alnum:]_./-]+)\))?(!)?:[[:space:]](.+)$ ]]; then
                local commit_type="${BASH_REMATCH[1],,}"
                local scope="${BASH_REMATCH[3]:-}"
                local is_breaking="${BASH_REMATCH[4]:-}"
                local description="${BASH_REMATCH[5]}"

                if [ -n "$scope" ]; then
                    subject_text="**${scope}:** ${description}"
                else
                    subject_text="$description"
                fi

                case "$commit_type" in
                    feat)
                        append_unique_changelog_line up_features up_seen_features "* ${subject_text}"
                        if [ "$up_bump_level" != "major" ] && [ "$up_bump_level" != "minor" ]; then
                            up_bump_level="minor"
                        fi
                        ;;
                    fix)
                        append_unique_changelog_line up_bug_fixes up_seen_bug_fixes "* ${subject_text}"
                        if [ "$up_bump_level" = "none" ]; then
                            up_bump_level="patch"
                        fi
                        ;;
                    perf)
                        append_unique_changelog_line up_perf_improvements up_seen_perf_improvements "* ${subject_text}"
                        if [ "$up_bump_level" = "none" ]; then
                            up_bump_level="patch"
                        fi
                        ;;
                    revert)
                        append_unique_changelog_line up_reverts up_seen_reverts "* ${subject_text}"
                        if [ "$up_bump_level" = "none" ]; then
                            up_bump_level="patch"
                        fi
                        ;;
                    docs|style|refactor|test|build|ci|chore)
                        append_unique_changelog_line up_maintenance up_seen_maintenance "* ${subject_text}"
                        ;;
                    *)
                        append_unique_changelog_line up_others up_seen_others "* ${subject_text}"
                        ;;
                esac

                if [ -n "$is_breaking" ] || [[ "$body" == *"BREAKING CHANGE:"* ]] || [[ "$body" == *"BREAKING-CHANGE:"* ]]; then
                    append_unique_changelog_line up_breaking_changes up_seen_breaking_changes "* ${subject_text}"
                    up_bump_level="major"
                fi
            else
                append_unique_changelog_line up_others up_seen_others "* ${subject_text}"
            fi
        done < <(git log --no-merges --reverse --pretty=tformat:'%s%x1f%b%x1e' "${latest_tag}..HEAD")

        if [ "${#up_features[@]}" -gt 0 ] \
            || [ "${#up_bug_fixes[@]}" -gt 0 ] \
            || [ "${#up_perf_improvements[@]}" -gt 0 ] \
            || [ "${#up_reverts[@]}" -gt 0 ] \
            || [ "${#up_maintenance[@]}" -gt 0 ] \
            || [ "${#up_others[@]}" -gt 0 ] \
            || [ "${#up_breaking_changes[@]}" -gt 0 ]; then

            local up_major=0
            local up_minor=0
            local up_patch=0
            local next_upcoming_version="$latest_version"

            if [[ "$latest_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
                up_major="${BASH_REMATCH[1]}"
                up_minor="${BASH_REMATCH[2]}"
                up_patch="${BASH_REMATCH[3]}"

                case "$up_bump_level" in
                    major)
                        up_major=$((up_major + 1))
                        up_minor=0
                        up_patch=0
                        ;;
                    minor)
                        up_minor=$((up_minor + 1))
                        up_patch=0
                        ;;
                    patch)
                        up_patch=$((up_patch + 1))
                        ;;
                    none)
                        ;;
                esac

                next_upcoming_version="${up_major}.${up_minor}.${up_patch}"
            fi

            printf '## %s (%s)\n\n' "$next_upcoming_version" "$upcoming_date"

            if [ "${#up_features[@]}" -gt 0 ]; then
                printf '### Features\n\n'
                printf '%s\n' "${up_features[@]}"
                printf '\n'
            fi

            if [ "${#up_bug_fixes[@]}" -gt 0 ]; then
                printf '### Bug Fixes\n\n'
                printf '%s\n' "${up_bug_fixes[@]}"
                printf '\n'
            fi

            if [ "${#up_perf_improvements[@]}" -gt 0 ]; then
                printf '### Performance Improvements\n\n'
                printf '%s\n' "${up_perf_improvements[@]}"
                printf '\n'
            fi

            if [ "${#up_reverts[@]}" -gt 0 ]; then
                printf '### Reverts\n\n'
                printf '%s\n' "${up_reverts[@]}"
                printf '\n'
            fi

            if [ "${#up_maintenance[@]}" -gt 0 ]; then
                printf '### Maintenance\n\n'
                printf '%s\n' "${up_maintenance[@]}"
                printf '\n'
            fi

            if [ "${#up_others[@]}" -gt 0 ]; then
                printf '### Other Changes\n\n'
                printf '%s\n' "${up_others[@]}"
                printf '\n'
            fi

            if [ "${#up_breaking_changes[@]}" -gt 0 ]; then
                printf '### BREAKING CHANGES\n\n'
                printf '%s\n' "${up_breaking_changes[@]}"
                printf '\n'
            fi
        fi

        local i
        for i in "${!tag_names[@]}"; do
            local current_tag="${tag_names[$i]}"
            local current_version="${tag_versions[$i]}"
            local previous_tag=""
            local tag_date

            if [ "$i" -lt "$(( ${#tag_names[@]} - 1 ))" ]; then
                previous_tag="${tag_names[$((i + 1))]}"
            fi

            tag_date="$(git log -1 --format=%cs "$current_tag")"

            local log_range
            if [ -n "$previous_tag" ]; then
                log_range="${previous_tag}..${current_tag}"
            else
                log_range="$current_tag"
            fi

            local -a features=()
            local -a bug_fixes=()
            local -a perf_improvements=()
            local -a reverts=()
            local -a breaking_changes=()
            local -a maintenance=()
            local -a others=()

            declare -A seen_features=()
            declare -A seen_bug_fixes=()
            declare -A seen_perf_improvements=()
            declare -A seen_reverts=()
            declare -A seen_breaking_changes=()
            declare -A seen_maintenance=()
            declare -A seen_others=()

            while IFS= read -r -d $'\x1e' entry; do
                [ -z "$entry" ] && continue

                entry="${entry#$'\n'}"

                local subject="${entry%%$'\x1f'*}"
                local body="${entry#*$'\x1f'}"
                local subject_text="$subject"

                if [[ "$subject" =~ ^([a-zA-Z]+)(\(([[:alnum:]_./-]+)\))?(!)?:[[:space:]](.+)$ ]]; then
                    local commit_type="${BASH_REMATCH[1],,}"
                    local scope="${BASH_REMATCH[3]:-}"
                    local is_breaking="${BASH_REMATCH[4]:-}"
                    local description="${BASH_REMATCH[5]}"

                    if [ -n "$scope" ]; then
                        subject_text="**${scope}:** ${description}"
                    else
                        subject_text="$description"
                    fi

                    case "$commit_type" in
                        feat)
                            append_unique_changelog_line features seen_features "* ${subject_text}"
                            ;;
                        fix)
                            append_unique_changelog_line bug_fixes seen_bug_fixes "* ${subject_text}"
                            ;;
                        perf)
                            append_unique_changelog_line perf_improvements seen_perf_improvements "* ${subject_text}"
                            ;;
                        revert)
                            append_unique_changelog_line reverts seen_reverts "* ${subject_text}"
                            ;;
                        docs|style|refactor|test|build|ci|chore)
                            append_unique_changelog_line maintenance seen_maintenance "* ${subject_text}"
                            ;;
                        *)
                            append_unique_changelog_line others seen_others "* ${subject_text}"
                            ;;
                    esac

                    if [ -n "$is_breaking" ] || [[ "$body" == *"BREAKING CHANGE:"* ]] || [[ "$body" == *"BREAKING-CHANGE:"* ]]; then
                        append_unique_changelog_line breaking_changes seen_breaking_changes "* ${subject_text}"
                    fi
                else
                    append_unique_changelog_line others seen_others "* ${subject_text}"
                fi
            done < <(git log --no-merges --reverse --pretty=tformat:'%s%x1f%b%x1e' "$log_range")

            if [ "${#features[@]}" -eq 0 ] \
                && [ "${#bug_fixes[@]}" -eq 0 ] \
                && [ "${#perf_improvements[@]}" -eq 0 ] \
                && [ "${#reverts[@]}" -eq 0 ] \
                && [ "${#maintenance[@]}" -eq 0 ] \
                && [ "${#others[@]}" -eq 0 ] \
                && [ "${#breaking_changes[@]}" -eq 0 ]; then
                continue
            fi

            printf '## %s (%s)\n\n' "$current_version" "$tag_date"

            if [ "${#features[@]}" -gt 0 ]; then
                printf '### Features\n\n'
                printf '%s\n' "${features[@]}"
                printf '\n'
            fi

            if [ "${#bug_fixes[@]}" -gt 0 ]; then
                printf '### Bug Fixes\n\n'
                printf '%s\n' "${bug_fixes[@]}"
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

            if [ "${#maintenance[@]}" -gt 0 ]; then
                printf '### Maintenance\n\n'
                printf '%s\n' "${maintenance[@]}"
                printf '\n'
            fi

            if [ "${#others[@]}" -gt 0 ]; then
                printf '### Other Changes\n\n'
                printf '%s\n' "${others[@]}"
                printf '\n'
            fi

            if [ "${#breaking_changes[@]}" -gt 0 ]; then
                printf '### BREAKING CHANGES\n\n'
                printf '%s\n' "${breaking_changes[@]}"
                printf '\n'
            fi
        done
    } > "$DOCS_CHANGELOG_FILE"

    echo "Updated $DOCS_CHANGELOG_FILE"
}

if [ "$DOCS_MODE" -eq 1 ]; then
    update_docs_changelog
    exit 0
fi

get_latest_semver_tag() {
    git for-each-ref --format='%(refname:short)' refs/tags \
        | awk 'BEGIN { OFS="\t" } { v=$0; sub(/^v/, "", v); if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) print $0, v }' \
        | sort -t $'\t' -k2,2Vr \
        | head -n1 \
        | cut -f1
}

latest_tag="$(get_latest_semver_tag || true)"

# Fallback to closest reachable tag only when no semver tag exists at all.
if [ -z "$latest_tag" ]; then
    latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi

if [ -n "$latest_tag" ] && ! git merge-base --is-ancestor "$latest_tag" HEAD; then
    echo "WARN: latest semantic tag '$latest_tag' is not an ancestor of HEAD; generating changelog against global latest tag." >&2
fi

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
