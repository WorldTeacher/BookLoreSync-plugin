# Versioning System

The Booklore KOReader plugin uses **Semantic Versioning** with automatic version generation based on git tags.

## Overview

- Version format follows [Semantic Versioning 2.0.0](https://semver.org/): `MAJOR.MINOR.PATCH`
- Versions are automatically generated from git tags via `generate-version.sh`
- The plugin uses GitLab's semantic-release pipeline for automated releases

## Version Generation

### Automatic (CI/CD)

When semantic-release creates a new tag (e.g., `v1.0.0`), the CI/CD pipeline automatically:

1. Runs `generate-version.sh`
2. Generates `bookloresync.koplugin/version.lua` with version info
3. Updates `bookloresync.koplugin/_meta.lua` with the version
4. Packages the plugin as `bookloresync.koplugin.zip`

### Manual (Development)

For local development, run:

```bash
./generate-version.sh
```

This will:
- Detect the version from git tags (or use `0.0.0-dev` if no tags exist)
- Generate version information including commit hash and build date
- Update both `version.lua` and `_meta.lua`

## Version Information

The generated `version.lua` contains:

```lua
return {
    version = "1.2.3",              -- Semantic version from git tag
    version_type = "release",       -- "release" or "development"
    git_commit = "abc1234",         -- Short commit hash
    build_date = "2024-01-15T10:30:00Z",  -- ISO 8601 timestamp
}
```

## Version Detection Logic

1. **Tagged Commit** (Release)
   - Version: Exact tag (e.g., `v1.0.0`)
   - Type: `release`
   
2. **Commit After Tag** (Development)
   - Version: Tag + commits + hash (e.g., `v1.0.0-5-gabc1234`)
   - Type: `development`
   
3. **No Tags** (Early Development)
   - Version: `0.0.0-dev` or `0.0.0-dev+abc1234`
   - Type: `development`

## Viewing Version in Plugin

The version is displayed in the plugin's "About" menu:

1. Open KOReader
2. Navigate to: **Menu → Tools → Booklore Sync → About**
3. View version information including:
   - Version number
   - Version type (release/development)
   - Build date
   - Git commit hash

## Release Process

### Using Semantic Release

The project uses semantic-release with conventional commits:

1. **Feature commits** → Minor version bump
   ```
   feat: add book matching functionality
   ```

2. **Fix commits** → Patch version bump
   ```
   fix: resolve database migration issue
   ```

3. **Breaking changes** → Major version bump
   ```
   feat!: redesign API endpoints
   
   BREAKING CHANGE: API endpoints have changed
   ```

### Manual Release

If needed, you can manually create a release:

```bash
# Tag the release
git tag v1.2.3

# Push the tag
git push origin v1.2.3

# The CI/CD pipeline will automatically build and publish
```

## Version File Exclusion

The generated `version.lua` file is excluded from git:

- Listed in `.gitignore`
- Generated during build/release process
- Should NOT be committed to the repository

## Troubleshooting

### No version displayed in plugin

**Cause**: `version.lua` not generated  
**Solution**: Run `./generate-version.sh` before testing

### Wrong version in CI/CD

**Cause**: Script not run in pipeline  
**Solution**: Check `.gitlab-ci.yml` includes the version generation step

### Development version shows in release

**Cause**: Building from non-tagged commit  
**Solution**: Ensure you're building from a tagged release commit

## Integration with KOReader

The version is integrated into KOReader's plugin system:

- `_meta.lua` exports version for KOReader's plugin manager
- `version.lua` provides detailed version info for the plugin itself
- "About" menu displays version to users

## Examples

### Release Version
```
Version: 1.2.3
Type: release
Build: 2024-01-15T10:30:00Z
Commit: abc1234
```

### Development Version
```
Version: 1.2.3-5-gabc1234
Type: development
Build: 2024-01-15T14:20:00Z
Commit: abc1234
```

### Pre-release Version
```
Version: 0.0.0-dev
Type: development
Build: 2024-01-10T09:00:00Z
Commit: unknown
```
