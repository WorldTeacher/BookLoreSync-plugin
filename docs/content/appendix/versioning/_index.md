+++
title = "Documentation Versions"
weight = 1
+++

# Documentation Versions

This documentation site is published in several versions that correspond to the
plugin's release cycle.

| Version | Source | Description |
|---------|--------|-------------|
| latest | `main` branch | Current stable release. Updated with every push to `main`. |
| dev | `develop` branch | In-progress changes. May include unreleased features. |
| vX.Y.Z | Git tags | Point-in-time snapshot for each tagged release. |

## How versions work

The documentation is built from three sources:

- **`main` branch** — published as the **latest** version. These docs match
  the most recent stable plugin release.
- **`develop` branch** — published as **dev**. These docs may cover features
  that aren't yet shipped. Use these to preview upcoming changes.
- **Git tags** — each tagged release (`vX.Y.Z`) gets its own snapshot so you can
  browse the docs that were current when that version was published.

## Switching versions

Use the version picker in the top navigation bar to switch between versions.

The version picker shows:

- **latest** — the current stable documentation (shown with a badge)
- **dev** — bleeding-edge documentation from the develop branch
- **vX.Y.Z** — point-in-time snapshots for each tagged release

When you switch to a different version, the URL changes to include the version
path. You can also bookmark version-specific URLs directly.

## See also

- [Changelog](@/reference/changelog.md) — full version history of the plugin
