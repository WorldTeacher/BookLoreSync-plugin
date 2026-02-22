# [3.4.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/3.3.1...3.4.0) (2026-02-22)


### Bug Fixes

* **api:** improve error message formatting in extractErrorMessage function [release] ([4c93031](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/4c93031f38847f3b8f253e1d8da467c6b7c26245))
* **changelog:** change changelog match ([ef44eeb](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/ef44eeb151312ed51a4f41cb3e0e87e4e22547d7))
* **ci:** add submodul handling ([545a75a](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/545a75af7b0eaa6e033efb3f9aac039ad04cb928))
* **ci:** add workspace dir for zola ([61c0565](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/61c0565001c0cf40fc992416b03940580f8b3356))
* **database:** update schema version and relax constraints for pending annotations and ratings ([e8a94f6](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/e8a94f6f1cacec6e3aa384322a4036704df8de09))
* **documentation:** add sidebar template with table of contents, remove version picker ([33a88b5](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/33a88b55e52a85ca0111f3fafd421d95ed3bf7d8))
* **rating:** delay keyboard display in rating dialog to prevent crashes on Linux ([c190d10](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/c190d1003b59957762d72f7580e4c67b9a3a3542))
* **settings:** change upload strategy for notes ([f79df18](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/f79df181ca2fd8775fa94db23359dc67b2101ec7))
* **sync:** mark annotations as synced when CFI cannot be built ([60bf873](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/60bf873b21adb7d11f064b1aebf0609d3cd35faf))
* **update, log:** change path handling ([cc55ed9](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/cc55ed9ae775357214b23c026e2e5986ce9483d3))


### Features

* **api:** add annotation support ([11c43b3](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/11c43b308f27c7af9e2c3c144be527c88fab6188))
* **api:** add submitRating function for personal book ratings ([6f9c90f](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/6f9c90f3696463b69665a6db8089f1907e93599b))
* **database:** add annotation sync helpers for KOReader ([366893f](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/366893fdedfd7849ff1f31eae66c5ae79157b2ed))
* **database:** update schema to version 9 and add book metadata sync functionality ([60db3ed](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/60db3eddb45f7706e5f3c6930a059cac0d5983cf))
* **docs:** add documentation and zola support ([edb0c03](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/edb0c03cf729468b975f1bea66c613ce1c8198ac))
* **metadata:** add metadata parser ([a483cb1](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/a483cb1a5512da18583b8014d5f76e8c37cec074))
* **notes:** add  color mapping, cfi generation, sync  for notes ([2586a9b](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/2586a9b74d306fd00ee592978e05b544d96ae791))
* **rating:** enhance rating sync with live in-memory support and retry mechanism ([ff3099d](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/ff3099d0327bd858ffc9abc6ac35906752038f49))
* **rating:** respect user settings for rating sync and improve handling of deferred ratings ([823b5b6](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/823b5b688f376e597d8938fe19413665d4b53a20))
* **settings:** add new sync menu for ratings and notes ([70556f2](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/70556f2cbf3a2344a518652cc68bbb66ba4025a6))
* **settings:** rework clear cache to select entries to be cleared on category level ([6d33867](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/6d338676454bbb2f0375667f87fa5dddbcc8b2e6))
* **settings:** sanitize server URL input and enhance connection test messages ([c03eae3](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/c03eae32fa4a446a4d1a8ac31509f0a87c17875e))
* **sync:** enhance session details view and improve pending uploads handling ([b3b91eb](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/b3b91ebeb7eea9c077fdf976b60cf7da6c8aa9ba))

## [3.3.1](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/3.3.0...3.3.1) (2026-02-20)


### Bug Fixes

* **reading-session:** correct page retrieval method for EPUB format ([4daef0b](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/4daef0b87a9817cb2628d005409c7a72b9d12711))

# [3.3.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/3.2.0...3.3.0) (2026-02-19)


### Features

* **sessions:** add support for pdf and archive-type formats ([a0599c4](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/a0599c485db664b8e545da0d23ede025dcd0274b))

# [3.2.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/3.1.0...3.2.0) (2026-02-16)


### Bug Fixes

* **database:** improve journal mode handling for better reliability ([f65f871](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/f65f8711490b6d43fbb54e407f174cf713d4f550))


### Features

* **logging:** enhance file logging with initialization and closure handling ([e6ca635](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/e6ca635800ad21adb6dd6b53a1d490926b576752))
* **logging:** implement file-based logging with daily rotation and automatic cleanup ([8bb03e8](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/8bb03e839331ed5c6fa1583208b94450c5577470))

# [3.1.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/3.0.0...3.1.0) (2026-02-16)


### Bug Fixes

* **sync:** fallback to individual upload on 403 Forbidden ([0c1b188](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/0c1b188bfdc9fe6f6718fb1ee3e9ee107ebcd302))
* **sync:** handle nil progress values in session processing and batch uploads ([15186b0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/15186b084bed0e50a84aaddf6a436699faf79e3a))


### Features

* **api:** add batch session upload endpoint with intelligent batching ([4d57c87](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/4d57c87a31ccef9eff6a750525327fa926b47a2a))

# [3.0.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/2.0.0...3.0.0) (2026-02-16)


### Bug Fixes

* **menu:** use text_func instead of text for dynamic pending count ([2746755](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/27467557865b13c71a4c9921240ab84cfe97091e))
* **updater:** handle HTTP redirects manually for KOReader compatibility ([1bbd5ab](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/1bbd5abca1f80b3e5ba4c7200fdb307837313bc1))
* **updater:** remove duplicate restart confirmation dialog ([e8df896](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/e8df89609139f3fd833155c7cae19abf4c137db7))
* **updater:** use correct lfs library path for KOReader ([b5006eb](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/b5006ebade41a376203e5aab2406036e49a6a409))


### Features

* add auto-updater system with GitHub integration ([88b4558](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/88b4558331099e6ee4cb768090abb6d139eb83a5))


### BREAKING CHANGES

* Database schema version 7 -> 8, requires migration

New Features:
- Auto-update check on startup (configurable)
- Manual update check with changelog preview
- One-tap update installation
- Automatic version backup before update
- Rollback support if update fails
- Update cache to respect GitHub API rate limits
- Download size display in confirmation dialog
- Progress tracking during download
- Restart prompt after successful update

Technical Details:
- booklore_updater.lua: ~500 lines, 734 total with comments
- main.lua: +368 lines (7 new functions)
- booklore_database.lua: +93 lines (Migration 8 + cache functions)
- features.md: Updated to 119 total features (88.2% implemented)
- All Lua syntax checks passed
- All version comparison tests passed (9/9)
- GitHub API integration verified
- Download mechanism validated

Files Added:
- bookloresync.koplugin/booklore_updater.lua
- AUTO_UPDATER_TESTING.md (comprehensive test checklist)
- test_updater.lua (standalone version comparison tests)
- features.md (feature tracking document)

Files Modified:
- bookloresync.koplugin/main.lua (new About & Updates menu)
- bookloresync.koplugin/booklore_database.lua (Migration 8)
- README.md (auto-update documentation)

# [2.0.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.1.1...2.0.0) (2026-02-16)


### Bug Fixes

* **updater:** handle HTTP redirects manually for KOReader compatibility ([6fd4dae](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/6fd4dae63213a00bf49b00eff99a0a0f11cca579))
* **updater:** remove duplicate restart confirmation dialog ([161a0c0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/161a0c031c2a761417c2d11edc225b5b03d095d8))
* **updater:** use correct lfs library path for KOReader ([f521b1c](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/f521b1c10c162bbf612492cafcf15c733c97ee1e))


### Features

* add auto-updater system with GitHub integration ([7ae0d61](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/7ae0d61f29b716785973426e0008914d029df975))


### BREAKING CHANGES

* Database schema version 7 -> 8, requires migration

New Features:
- Auto-update check on startup (configurable)
- Manual update check with changelog preview
- One-tap update installation
- Automatic version backup before update
- Rollback support if update fails
- Update cache to respect GitHub API rate limits
- Download size display in confirmation dialog
- Progress tracking during download
- Restart prompt after successful update

Technical Details:
- booklore_updater.lua: ~500 lines, 734 total with comments
- main.lua: +368 lines (7 new functions)
- booklore_database.lua: +93 lines (Migration 8 + cache functions)
- features.md: Updated to 119 total features (88.2% implemented)
- All Lua syntax checks passed
- All version comparison tests passed (9/9)
- GitHub API integration verified
- Download mechanism validated

Files Added:
- bookloresync.koplugin/booklore_updater.lua
- AUTO_UPDATER_TESTING.md (comprehensive test checklist)
- test_updater.lua (standalone version comparison tests)
- features.md (feature tracking document)

Files Modified:
- bookloresync.koplugin/main.lua (new About & Updates menu)
- bookloresync.koplugin/booklore_database.lua (Migration 8)
- README.md (auto-update documentation)

## [1.1.1](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.1.0...1.1.1) (2026-02-15)


### Bug Fixes

* tag version in github ([189ed4d](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/189ed4de7e47dec2961753392054c047aa1cd5db))

# [1.1.0](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.5...1.1.0) (2026-02-15)


### Features

* log obfuscation ([ca3be43](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/ca3be4300e0f095039d6a0c3df8ea496389058b3))

## [1.0.5](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.4...1.0.5) (2026-02-15)


### Bug Fixes

* another ci ([98cd6d4](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/98cd6d4fd232ea3179c50fb672b98f051aafa841))

## [1.0.4](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.3...1.0.4) (2026-02-15)


### Bug Fixes

* new ci ([54e3ce5](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/54e3ce5c98f244a8340884608d383ca19010cf9b))

## [1.0.3](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.2...1.0.3) (2026-02-15)


### Bug Fixes

* new ci ([2d81d24](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/2d81d24f38f83ace8398bc59cfc1332ead6be691))

## [1.0.2](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.1...1.0.2) (2026-02-15)


### Bug Fixes

* ci now allows addition? ([e8d2075](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/e8d2075652cfad1182f8f0e4dd1c0d7e570947bb))

## [1.0.1](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/compare/1.0.0...1.0.1) (2026-02-15)


### Bug Fixes

* ci file ([22f3826](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/22f382666c8ab11d7d4f258b9609dbabaeb9add9))

# 1.0.0 (2026-02-15)


### Bug Fixes

* **network:** add missing options ([50dc1bf](https://gitlab.worldteacher.dev/WorldTeacher/booklore-koreader-plugin/commit/50dc1bfd03ef84414647cc00c2bbebfb6d838878))
