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
