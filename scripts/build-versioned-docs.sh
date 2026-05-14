#!/bin/bash
# Build versioned documentation for GitLab Pages
#
# This script:
# 1. Discovers all documentation versions from git (main → latest, develop → dev, tags)
# 2. Builds each version with the correct base_url and version picker config
# 3. Assembles the public/ directory for GitLab Pages deployment
#
# Prerequisites:
#   - git (with full history, set GIT_DEPTH=0 in CI)
#   - zola binary in PATH
#   - Should be run from the repository root inside docs/
#     (or with DOCS_DIR env pointing to the docs directory)
#
# Environment variables:
#   CI_PROJECT_DIR     GitLab CI project directory
#   CI_COMMIT_SHA      Current commit SHA (to restore checkout)
#   CI_COMMIT_TAG      Current tag (if building for a tag)
#   CI_COMMIT_BRANCH   Current branch (if building for a branch)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

DOCS_DIR="${DOCS_DIR:-$REPO_ROOT/docs}"
PUBLIC_DIR="${PUBLIC_DIR:-$REPO_ROOT/public}"
BASE_URL="${BASE_URL:-https://docs.worldteacher.dev/wt-booklore/booklore-koreader-plugin}"
MAX_TAGS="${MAX_TAGS:-10}"

echo "=== Versioned Docs Builder ==="
echo "Base URL: $BASE_URL"
echo "Docs dir: $DOCS_DIR"
echo "Output:   $PUBLIC_DIR"
echo "Max tags: $MAX_TAGS"

# ── Phase 1: Fetch all branches and tags ──────────────────────────────
echo ""
echo "=== Phase 1: Fetching branches and tags ==="

# Ensure we have the branches and tags we need
git fetch origin main develop --depth=1 2>/dev/null || echo "  (some branches not found, continuing)"
git fetch origin --tags 2>/dev/null || echo "  (could not fetch tags)"
# Fetch more history so tag annotations are available
git fetch --unshallow 2>/dev/null || true

# ── Phase 2: Discover versions ────────────────────────────────────────
echo ""
echo "=== Phase 2: Discovering versions ==="

# Format per entry: label|ref|path|display
#   label:   logical name ("latest", "dev", or tag name)
#   ref:     git ref to checkout
#   path:    URL path suffix (empty for root)
#   display: shown in the version picker button/dropdown

VERSIONS=()

# Main branch → latest
if git show-ref --verify refs/remotes/origin/main &>/dev/null 2>&1; then
    TAG_ON_MAIN=$(git tag --merged origin/main --sort=-version:refname 2>/dev/null | grep -v '^v' | head -1 || true)
    if [ -n "$TAG_ON_MAIN" ]; then
        # Latest tag on main → use it for the display version (no v prefix)
        DISPLAY="${TAG_ON_MAIN#v}"
    else
        DISPLAY="latest"
    fi
    VERSIONS+=("latest|origin/main|.|$DISPLAY")
    echo "  [latest]  main → $DISPLAY"
else
    echo "  [SKIP]    main branch not found"
fi

# Develop branch → dev
if git show-ref --verify refs/remotes/origin/develop &>/dev/null 2>&1; then
    VERSIONS+=("dev|origin/develop|dev|dev")
    echo "  [dev]     develop → dev"
else
    echo "  [SKIP]    develop branch not found"
fi

# Tags → versioned releases (newest first, capped at MAX_TAGS)
TAG_COUNT=0
while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    [ "$TAG_COUNT" -ge "$MAX_TAGS" ] && break

    # Display version without v prefix (template adds no prefix)
    TAG_DISPLAY="${tag#v}"

    # URL path uses the raw tag name
    VERSIONS+=("$tag|refs/tags/$tag|$tag|$TAG_DISPLAY")
    TAG_COUNT=$((TAG_COUNT + 1))
done < <(git tag --sort=-version:refname 2>/dev/null)

echo "  [$TAG_COUNT tags]  (showing newest $MAX_TAGS)"

echo ""
echo "Discovered ${#VERSIONS[@]} versions total."

# ── Phase 3: Build each version ───────────────────────────────────────
echo ""
echo "=== Phase 3: Building versions ==="

# Store the original commit ref so we can restore at the end
ORIGINAL_REF="${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"

for version_info in "${VERSIONS[@]}"; do
    # Parse the version entry
    IFS='|' read -r label ref path display <<< "$version_info"

    echo ""
    echo "────────────────────────────────────────────"
    echo "  Building: $label"
    echo "    ref:     $ref"
    echo "    path:    $path"
    echo "    display: $display"

    # Checkout the version
    if ! git checkout "$ref" --force 2>/dev/null; then
        echo "  WARNING: Could not checkout $ref, skipping"
        continue
    fi

    # Reinitialize submodules (theme may have changed between branches/tags)
    git submodule update --init --recursive 2>/dev/null || true

    # Determine base_url and output directory
    if [ -z "$path" ] || [ "$path" = "." ]; then
        version_base_url="$BASE_URL"
        output_dir="$PUBLIC_DIR"
    else
        version_base_url="$BASE_URL/$path"
        output_dir="$PUBLIC_DIR/$path"
    fi

    mkdir -p "$output_dir"
    echo "    base_url: $version_base_url"
    echo "    output:   $output_dir"

    # Generate the full version list TOML (same list for every build)
    # so the version picker shows all available versions regardless of which
    # version you're viewing.
    version_list=""
    for v in "${VERSIONS[@]}"; do
        IFS='|' read -r vl vr vp vd <<< "$v"

        # URL for this version entry
        if [ -z "$vp" ] || [ "$vp" = "." ]; then
            v_url="$BASE_URL/"
        else
            v_url="$BASE_URL/$vp/"
        fi

        # Build TOML entry
        if [ "$vl" = "latest" ]; then
            version_list="$version_list    { version = \"$vd\", url = \"$v_url\", label = \"latest\" },
"
        elif [ "$vl" = "dev" ]; then
            version_list="$version_list    { version = \"$vd\", url = \"$v_url\", label = \"dev\" },
"
        else
            version_list="$version_list    { version = \"$vd\", url = \"$v_url\" },
"
        fi
    done

    # Read the tracked zola.toml for common settings, but override
    # base_url and the versions section for this specific build.
    # We generate a temporary config to avoid modifying tracked files.
    cat > "$DOCS_DIR/zola.versioned.toml" << 'ZOLAEOF'
base_url = "TEMPLATE_BASE_URL"
title = "Booklore Sync - KOReader Plugin"
description = "Official documentation for the Booklore Sync KOReader plugin. Automatically track reading sessions, sync ratings, highlights, and notes to your self-hosted Booklore server."
theme = "tanuki"
compile_sass = true
build_search_index = true

[markdown]
insert_anchor_links = "left"

[extra]
mode = "docs"
gitlab = "https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin"
show_theme_toggle = true

[extra.versions]
current = "TEMPLATE_CURRENT"
list = [
TEMPLATE_VERSION_LIST
]
ZOLAEOF

    # Fill in the template placeholders
    # Use @ as sed delimiter since URLs contain /
    sed -i "s@TEMPLATE_BASE_URL@$version_base_url@g" "$DOCS_DIR/zola.versioned.toml"
    sed -i "s@TEMPLATE_CURRENT@$display@g" "$DOCS_DIR/zola.versioned.toml"

    # Write the version list (multi-line, careful with sed)
    # We use a Python one-liner if available, otherwise awk
    if command -v python3 &>/dev/null; then
        python3 -c "
import sys
content = open('$DOCS_DIR/zola.versioned.toml').read()
version_list = '''$version_list'''
content = content.replace('TEMPLATE_VERSION_LIST', version_list.rstrip('\n'))
open('$DOCS_DIR/zola.versioned.toml', 'w').write(content)
"
    else
        # Fallback: use awk for multi-line replacement
        awk -v list="$version_list" '
        /TEMPLATE_VERSION_LIST/ { gsub(/TEMPLATE_VERSION_LIST/, list) }
        { print }
        ' "$DOCS_DIR/zola.versioned.toml" > "$DOCS_DIR/zola.versioned.toml.tmp" \
        && mv "$DOCS_DIR/zola.versioned.toml.tmp" "$DOCS_DIR/zola.versioned.toml"
    fi

    # Build with the temporary config
    echo "    Running: zola build ..."
    cd "$DOCS_DIR"
    if ! zola --config zola.versioned.toml build \
        --base-url "$version_base_url" \
        --output-dir "$output_dir" 2>&1; then
        echo "  WARNING: zola build failed for $label, continuing"
    fi

    # Clean up temp config
    rm -f zola.versioned.toml zola.versioned.toml.tmp

    cd "$REPO_ROOT"
    echo "  ✓ Completed: $label"
done

# ── Phase 4: Restore repo state ───────────────────────────────────────
echo ""
echo "=== Phase 4: Restoring repo state ==="
git checkout "$ORIGINAL_REF" --force 2>/dev/null || \
    git checkout main --force 2>/dev/null || true

# ── Phase 5: Verify output ────────────────────────────────────────────
echo ""
echo "=== Build Complete ==="
echo ""
echo "Public directory contents:"
find "$PUBLIC_DIR" -maxdepth 1 -type d | sort
echo ""

# Check that the essential pages exist
ESSENTIAL_COUNTER=0
for f in "$PUBLIC_DIR/index.html" "$PUBLIC_DIR/dev/index.html"; do
    if [ -f "$f" ]; then
        ESSENTIAL_COUNTER=$((ESSENTIAL_COUNTER + 1))
    fi
done
echo "Essential pages: $ESSENTIAL_COUNTER/2 (index.html + dev/index.html)"
echo "Tag version directories: $(find "$PUBLIC_DIR" -maxdepth 1 -type d -name 'v*' | wc -l)"

# Warn if no versions were built
if [ "$ESSENTIAL_COUNTER" -eq 0 ]; then
    echo ""
    echo "WARNING: No documentation versions were built!"
    echo "This means GitLab Pages will have no content."
    echo ""
    echo "If you're running this locally without all branches, use:"
    echo "  git fetch origin main develop --tags"
fi

echo ""
echo "Done."
