+++
title = "Changelog"
description = "Full version history for the BookLore Sync plugin."
weight = 4
+++

# Changelog

All notable changes to the BookLore Sync plugin are documented here.

---

## 4.3.0 (2026-05-09)

### Features

* **reading-status:** add functionality to update reading status for books
* **menu:** implement file dialog actions for syncing and tracking books
* **shelf-sync:** implement private shelf sync support with explicit ID...

### Bug Fixes

* **migration:** store migration in database
* **menu:** remove double reading status entry, update makefile
* **menu:** move reading status into row 3
* **progress:** better timestamp handling for past timestamps
* **progress:** implement progress sync enabled state recovery from persisted settings

### Maintenance

* **docs:** update docs regarding silent mode
* **makefile:** update makefile
* **makefile:** update available commands and improve help output
* **scripts:** add changelog pregen script

### Other Changes

* Bugfix/refactor main file
* Feature/set read status

## 4.2.0 (2026-04-26)

### Features

* **settings:** add deletePluginSetting method and integrate into DbSettings...
* **settings:** add network connect timeout configuration and integrate into sync process
* **networking:** connection switch

### Bug Fixes

* **database:** enhance clearBookCache to safely manage dependencies and improve logging
* **network:** add 'run until connect' option for network connection handling
* **sync:** implement WiFi request handling for various sync operations and...
* **menu:** reorganize networking options for WiFi connection behavior
* **network:** implement fallback for sleep function in network connection handling

### Maintenance

* **tests:** remove deprecated URL handling tests and airplane mode checks
* **docs:** update documentation for changed networking rules
* **i10n:** update translations
* **semantic-release:** release 4.2.0 - [skip ci on prod]

## 4.1.1 (2026-04-19)

### Bug Fixes

* **upload:** upload sessions on resume from sleep
* **sync:** enhance auto-sync on suspend to queue and upload session/progress immediately

### Performance Improvements

* **sync:** change upload to be deferred

### Maintenance

* **makefile:** add Makefile for test and documentation commands
* **semantic-release:** release 4.1.1 - [skip ci on prod]

### Other Changes

* Revert "Merge branch 'upload-on-resume-from-sleep-if-automatic' into 'develop'"

## 4.1.0 (2026-04-12)

### Features

* **sync:** add session location normalization and metadata resync functionality
* **sync:** add progress sync gestures
* **ci:** add Lua formatting, translation validation, and test stages to CI pipeline
* **perf:** improve performance for sync, exit, periodic progress

### Bug Fixes

* **menu:** restructure main menu items for improved organization and clarity
* **localization:** update translations for shelf sync and related settings
* **localization:** remove outdated translation for shelf sync
* **menu:** rename shelf downloads menu to shelf sync for clarity
* **localization:** update translations for shelf sync settings
* **ci:** change stages of Lua formatting and validation checks from test to build
* **ci:** update stages for Lua formatting and validation checks to run in the test stage
* **ci:** add production stage to CI pipeline
* **ci:** update workflow rules for CI pipeline to include push events on develop and main branches
* **ci:** update lua-format-check image to specific version 2.4.1
* **ci:** update lua-format-check to use alpine image and install Stylua dynamically
* **ci:** update lua-tests before_script to use quotes for command execution
* **ci:** update lua-format-check to download Stylua version 2.4.1 directly
* **ci:** update lua-tests before_script to use a multi-line command for installing dependencies
* **ci:** update lua-format-check to download Stylua for musl and improve version check
* **ci:** update lua-format-check to download Stylua for x86_64 musl
* **ci:** update lua-tests before_script to install additional Lua dependencies and add random UUID generation
* **progress:** add functions to build and push KOReader progress payload
* **ci:** add openssl-dev to lua-tests before_script for dependency installation
* **sync:** no longer stores local state on open
* **tests:** fix tests
* **tests:** enhance Lua test coverage reporting and setup
* **ui:** fix reading sessions in show data, progress decimals

### Maintenance

* **docs:** update progress sync instructions for clarity and add session location normalization option
* **sync:** streamline annotation processing and remove lua-format-check job
* **docs:** update file manager actions, gestures, and dispatcher actions documentation; enhance changelog with new features and improvements
* **semantic-release:** release 4.1.0 - [skip ci on prod]

### Other Changes

* fix(progress sync): update session location normalization help text for clarity and detail
* Fix progress dialog at 0%

## 4.0.1 (2026-04-05)

### Bug Fixes

* **menu:** restructure main menu items for improved organization and clarity

### Maintenance

* **semantic-release:** release 4.0.1 - [skip ci on prod]

## 4.0.0 (2026-04-05)

### Features

* **database:** add functions to count pending and synced annotations and bookmarks for a specific book
* **storage:** implement disk space check and file size retrieval before downloads
* **database:** add shelf state caching for delta-based sync
* **advanced:** add data management options for clearing synced history and re-matching books
* **database:** add function to delete pending ratings by book_cache_id
* **updater:** add user file preservation and restoration during updates
* **branding:** implement branding functionality for customizable display names
* **localization:** update German translations for improved clarity and accuracy

### Bug Fixes

* **settings:** improve error handling for saving settings
* **koreader:** update plugin name to 'bookloresync' to allow plugin to be disabled
* **ci:** update quotes for tag condition in workflow rules
* **ci:** remove unnecessary release rules from workflow
* **ci:** update pipeline rules for main branch and document changes
* **updater:** improve user file restoration error handling
* **settings:** streamline input handling for minimum duration and pages configuration
* **api_client:** enhance progress update validation for timestamp and percentage
* **api_client:** simplify logging methods by removing redundant checks
* **api_client:** enhance error handling and logging for getBookFileSize method
* **ci:** update version generation to support override from CI environment
* **database:** update schema version and modify pending progress handling
* **branding:** improve branding functionality by handling missing branding module and simplifying function signatures
* **branding:** handle missing branding module gracefully and provide default implementations
* **branding:** improve display name handling and use unique placeholders in apply function
* **settings:** enhance error handling for saving progress decimal places

### Maintenance

* **ci:** add build job for generating and compiling koplugin artifacts
* **ci:** change build stage to test for koplugin artifact generation
* **ci:** change build stage to build and update rules for merge request targeting main
* **logs:** rework logging mechanism and remove secure logging option
* **release:** update plugin name to 'bookloresync' in version generation script
* **ci:** add package upload as reference
* **ci:** new upload strategy for dev builds
* **plugin:** dev build implementation
* **docs:** update documentation for progress sync feature and related settings
* **translation:** update thranslations
* **docs:** update documentation for plugin naming and branding settings
* **docs:** update changelog in docs
* **settings:** redesign settings for easier navigation
* **docs:** refine description for connect_network_on_suspend setting
* **semantic-release:** release 4.0.0 - [skip ci on prod]

### Other Changes

* feat(progress sync): Implement KOReader progress sync functionality

### BREAKING CHANGES

* **settings:** enhance error handling for saving progress decimal places

## 3.8.4 (2026-03-16)

### Bug Fixes

* **release:** simplify plugin archive creation in CI workflows

### Maintenance

* **semantic-release:** release 3.8.4 - [skip ci on prod]

## 3.8.3 (2026-03-16)

### Bug Fixes

* **release:** correct plugin archive creation path in workflow

### Maintenance

* **semantic-release:** release 3.8.3 - [skip ci on prod]

## 3.8.2 (2026-03-16)

### Features

* **settings:** add settiings export for debug
* probe by-hash endpoint in test connection
* add Manual Matching placeholder to Import Reading History menu
* **db:** add hardcover_id column to book_cache (migration 16)
* **hardcover:** add debug menu with 'Request book metadata from BookLore' action
* add file manager hold menu items (sync annotations, match book, sync rating)
* **ui:** register file manager hold menu actions for syncing annotations, matching book, and syncing rating
* add file manager hold menu items (sync annotations, match book, sync rating)
* **annotations:** add 'Both' destination and PDF mock CFI support
* **bookmarks:** sync bookmarks to Booklore via api/v1/bookmarks
* **sync:** implement hardcover rating sync with token validation and fallback search
* **settings:** add hardcover token configuration and rating sync options
* **hardcover:** implement Hardcover API client and integrate with BookloreSync for rating and book search
* **database:** add hardcover_id column to book_cache for rating sync
* **sync:** add bookmarks sync functionality and update related methods; add check for existing annotations
* **deletion:** notify Booklore when books are deleted from file manager
* **resume:** add 5min cooldown, deferred wake sync, onNetworkConnected
* **shelf-sync:** pull books from Booklore shelf with bidirectional sync
* **shelf-sync:** smart download dir detection + shelf name/dir config UI
* **skip-book:** per-book tracking toggle via file manager long-press
* **sync:** add bookmarks sync configuration and toggle functionality
* **metadata:** enhance bookmark extraction from DocSettings and improve filtering logic
* **bookmarks:** calculate bookmark cfi
* **wifi:** add user confirmation for enabling WiFi before syncing
* **sync:** enhance book synchronization with interactive matching and improved UI dialogs
* **test:** Add unit tests for BookloreSync and Updater helper functions
* **docs:** add versioned docs with version selector
* **release:** trigger major version bump [release]
* **api:** add ISBN lookup functionality to retrieve book ID
* **isbn:** extract ISBN from KOReader doc settings and use as fallback for book lookup
* **sync:** enhance shelf synchronization with improved subprocess handling and user feedback
* **translation:** convert every string to be translateable
* **translation:** add translation files

### Bug Fixes

* **logging:** enhance logging for batch upload sessions with book ID details
* **hardcover:** use self.server_url instead of self.booklore_url in fetchAndStoreHardcoverIds
* **main:** re-remove extended_sync
* **shelf-sync:** read KOReader home_dir for download dir detection
* **pop-up:** show synced / skipped for other areas
* **menu:** add function to integrate items into the main menu
* **menu:** update menu item text for fetching Hardcover Book IDs
* **database:** improve error handling in setBookTracking and isBookTrackingEnabled functions
* **sync:** improve user feedback in sync dialog for missing spine
* **ci:** streamline commit-analyzer configuration in release setup [release]
* **match:** show popup when hash lookup finds no match in Booklore [release]
* **ci:** change pipeline to always run
* **annotations:** save to both now actually uploads to both locations
* **isbn:** update ISBN lookup to use searchBooksByIsbn and handle exact match scoring
* **docs:** standardize punctuation in documentation for clarity
* **network:** fix bug in ask to enable wifi, fixes crash related to networking by using networkmanager
* **ci:** update butler rules to ensure proper execution based on GITLAB_TOKEN
* **ci:** comment out unused butler configuration in CI pipeline
* **ci:** add lua-tests stage to CI pipeline for improved testing coverage
* **ci:** add missing stages to CI pipeline configuration
* **ci:** rename lua-tests to lua-check and update testing commands
* **ci:** update lua-check to use luajit and adjust script for compatibility
* **ci:** restore butler configuration and remove unused lua-check stage
* **ci:** remove unused pipeline stages from configuration
* **sync:** improve shelf book synchronization and filename generation
* **gestures:** sync now gesture also asks for wifi to be enabled
* **menu:** keep menu open when input dialogs are shown
* **shelf:** add option to use original server filename for downloaded books
* **shelf-sync:** add sdr deletion and improved sidecar detection
* **sidecar:** fix and enhance sdr detection
* **sync:** capture bookmarks and annotations on device suspend
* **shelf-sync:** enhance filename generation and migration handling for shelf books
* **sync:** improve pending items count calculation and update sync messages
* **sync:** enhance language loading and improve pending items handling
* **.gitignore:** add missing patterns for gettext translations and new file types
* **pre-commit:** remove MAX_LINE_LENGTH environment variable

### Maintenance

* **ci:** add zola workspace to variables
* **documentation:** use @ links
* **tests:** add tests
* **documentation:** add reference for the custom image
* **readme:** remove troubleshooting steps for easier maintenance
* update highlights and notes sync status to 'Currently not working'
* **auto-match:** streamline hash matching process and enhance logging for auto-acceptance
* **database:** add methods to save and retrieve hardcover user ID
* **api:** resolve merge conflict and improve error handling in getBookById and submitBookmark functions
* **database:** update schema version to 20 and adjust migration index
* **menu:** streamline sync triggers and reintroduce hardcover integration
* **formatting:** enforce formatting
* **readme:** add testing instructions and coverage artifact details
* **ci:** remove test stage and associated run-tests job from CI pipeline
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **ci:** add stuff [release]
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **changelog:** reset changelog [release]
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **semantic-release:** release 3.5.0 - [skip ci on prod]
* **semantic-release:** release 3.5.1 - [skip ci on prod]
* **api:** remove ISBN lookup function from APIClient
* **docs:** update docs to reference the ISBN lookup and recommended workflow
* **ci:** butler change
* **semantic-release:** release 3.6.0 - [skip ci on prod]
* **semantic-release:** release 3.6.1 - [skip ci on prod]
* **sync:** replace AsyncTask with Trapper for improved synchronization handling and add comprehensive tests for shelf synchronization
* **docs:** update docs for sync shelf
* **semantic-release:** release 3.7.0 - [skip ci on prod]
* **gitlab:** add templates for issues and MRs
* **ci:** add translation compiling
* **i10n:** update translation for  sdr detection and deletion
* **documentation:** update documentation to explain updated functions
* **semantic-release:** release 3.8.0 - [skip ci on prod]
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **semantic-release:** release 1.0.0 - [skip ci on prod]

### Other Changes

* update ci
* Better annotation handling
* refactor(sync flow): resolve book_id first, then session/rating/annotations
* Fix shelf sync async tasks
* Edit README.md

### BREAKING CHANGES

* **release:** trigger major version bump [release]

## 3.8.1 (2026-03-16)

### Bug Fixes

* **.gitignore:** add missing patterns for gettext translations and new file types

### Maintenance

* **semantic-release:** release 3.8.1 - [skip ci on prod]

## 3.8.0 (2026-03-16)

### Features

* **translation:** convert every string to be translateable
* **translation:** add translation files

### Bug Fixes

* **menu:** keep menu open when input dialogs are shown
* **shelf:** add option to use original server filename for downloaded books
* **shelf-sync:** add sdr deletion and improved sidecar detection
* **sidecar:** fix and enhance sdr detection
* **sync:** capture bookmarks and annotations on device suspend
* **shelf-sync:** enhance filename generation and migration handling for shelf books
* **sync:** improve pending items count calculation and update sync messages
* **sync:** enhance language loading and improve pending items handling

### Maintenance

* **gitlab:** add templates for issues and MRs
* **ci:** add translation compiling
* **i10n:** update translation for  sdr detection and deletion
* **documentation:** update documentation to explain updated functions
* **semantic-release:** release 3.8.0 - [skip ci on prod]

## 3.7.0 (2026-03-11)

### Features

* **sync:** enhance shelf synchronization with improved subprocess handling and user feedback

### Bug Fixes

* **sync:** improve shelf book synchronization and filename generation

### Maintenance

* **sync:** replace AsyncTask with Trapper for improved synchronization handling and add comprehensive tests for shelf synchronization
* **docs:** update docs for sync shelf
* **semantic-release:** release 3.7.0 - [skip ci on prod]

### Other Changes

* Edit README.md

## 3.6.1 (2026-03-10)

### Bug Fixes

* **gestures:** sync now gesture also asks for wifi to be enabled

### Maintenance

* **semantic-release:** release 3.6.1 - [skip ci on prod]

## 3.6.0 (2026-03-10)

### Features

* **api:** add ISBN lookup functionality to retrieve book ID
* **isbn:** extract ISBN from KOReader doc settings and use as fallback for book lookup

### Bug Fixes

* **annotations:** save to both now actually uploads to both locations
* **isbn:** update ISBN lookup to use searchBooksByIsbn and handle exact match scoring
* **docs:** standardize punctuation in documentation for clarity
* **network:** fix bug in ask to enable wifi, fixes crash related to networking by using networkmanager
* **ci:** update butler rules to ensure proper execution based on GITLAB_TOKEN
* **ci:** comment out unused butler configuration in CI pipeline
* **ci:** add lua-tests stage to CI pipeline for improved testing coverage
* **ci:** add missing stages to CI pipeline configuration
* **ci:** rename lua-tests to lua-check and update testing commands
* **ci:** update lua-check to use luajit and adjust script for compatibility
* **ci:** restore butler configuration and remove unused lua-check stage
* **ci:** remove unused pipeline stages from configuration

### Maintenance

* **api:** remove ISBN lookup function from APIClient
* **docs:** update docs to reference the ISBN lookup and recommended workflow
* **ci:** butler change
* **semantic-release:** release 3.6.0 - [skip ci on prod]

## 3.5.1 (2026-03-09)

### Bug Fixes

* **match:** show popup when hash lookup finds no match in Booklore [release]
* **ci:** change pipeline to always run

### Maintenance

* **semantic-release:** release 3.5.1 - [skip ci on prod]

## 3.5.0 (2026-03-08)

### Features

* **release:** trigger semrel [release]

### Maintenance

* **semantic-release:** release 3.5.0 - [skip ci on prod]

## 3.4.1 (2026-03-08)

### Features

* log obfuscation
* add auto-updater system with GitHub integration
* add auto-updater system with GitHub integration
* **api:** add batch session upload endpoint with intelligent batching
* **logging:** implement file-based logging with daily rotation and automatic cleanup
* **logging:** enhance file logging with initialization and closure handling
* **sessions:** add support for pdf and archive-type formats
* **metadata:** add metadata parser
* **settings:** add new sync menu for ratings and notes
* **database:** update schema to version 9 and add book metadata sync functionality
* **api:** add submitRating function for personal book ratings
* **api:** add annotation support
* **database:** add annotation sync helpers for KOReader
* **notes:** add  color mapping, cfi generation, sync  for notes
* **rating:** enhance rating sync with live in-memory support and retry mechanism
* **rating:** respect user settings for rating sync and improve handling of deferred ratings
* **sync:** enhance session details view and improve pending uploads handling
* **settings:** rework clear cache to select entries to be cleared on category level
* **docs:** add documentation and zola support
* **settings:** sanitize server URL input and enhance connection test messages
* **settings:** add settiings export for debug
* probe by-hash endpoint in test connection
* add Manual Matching placeholder to Import Reading History menu
* **db:** add hardcover_id column to book_cache (migration 16)
* **hardcover:** add debug menu with 'Request book metadata from BookLore' action
* add file manager hold menu items (sync annotations, match book, sync rating)
* **ui:** register file manager hold menu actions for syncing annotations, matching book, and syncing rating
* add file manager hold menu items (sync annotations, match book, sync rating)
* **annotations:** add 'Both' destination and PDF mock CFI support
* **bookmarks:** sync bookmarks to Booklore via api/v1/bookmarks
* **sync:** implement hardcover rating sync with token validation and fallback search
* **settings:** add hardcover token configuration and rating sync options
* **hardcover:** implement Hardcover API client and integrate with BookloreSync for rating and book search
* **database:** add hardcover_id column to book_cache for rating sync
* **sync:** add bookmarks sync functionality and update related methods; add check for existing annotations
* **deletion:** notify Booklore when books are deleted from file manager
* **resume:** add 5min cooldown, deferred wake sync, onNetworkConnected
* **shelf-sync:** pull books from Booklore shelf with bidirectional sync
* **shelf-sync:** smart download dir detection + shelf name/dir config UI
* **skip-book:** per-book tracking toggle via file manager long-press
* **sync:** add bookmarks sync configuration and toggle functionality
* **metadata:** enhance bookmark extraction from DocSettings and improve filtering logic
* **bookmarks:** calculate bookmark cfi
* **wifi:** add user confirmation for enabling WiFi before syncing
* **sync:** enhance book synchronization with interactive matching and improved UI dialogs
* **test:** Add unit tests for BookloreSync and Updater helper functions
* **docs:** add versioned docs with version selector
* **release:** trigger major version bump [release]

### Bug Fixes

* **network:** add missing options
* ci file
* ci now allows addition?
* new ci
* new ci
* another ci
* tag version in github
* **updater:** handle HTTP redirects manually for KOReader compatibility
* **updater:** use correct lfs library path for KOReader
* **updater:** remove duplicate restart confirmation dialog
* **menu:** use text_func instead of text for dynamic pending count
* **updater:** handle HTTP redirects manually for KOReader compatibility
* **updater:** use correct lfs library path for KOReader
* **updater:** remove duplicate restart confirmation dialog
* **sync:** handle nil progress values in session processing and batch uploads
* **sync:** fallback to individual upload on 403 Forbidden
* **database:** improve journal mode handling for better reliability
* **reading-session:** correct page retrieval method for EPUB format
* **settings:** change upload strategy for notes
* **changelog:** change changelog match
* **rating:** delay keyboard display in rating dialog to prevent crashes on Linux
* **database:** update schema version and relax constraints for pending annotations and ratings
* **ci:** add workspace dir for zola
* **ci:** add submodul handling
* **documentation:** add sidebar template with table of contents, remove version picker
* **sync:** mark annotations as synced when CFI cannot be built
* **api:** improve error message formatting in extractErrorMessage function [release]
* **logging:** enhance logging for batch upload sessions with book ID details
* **hardcover:** use self.server_url instead of self.booklore_url in fetchAndStoreHardcoverIds
* **main:** re-remove extended_sync
* **shelf-sync:** read KOReader home_dir for download dir detection
* **pop-up:** show synced / skipped for other areas
* **menu:** add function to integrate items into the main menu
* **menu:** update menu item text for fetching Hardcover Book IDs
* **database:** improve error handling in setBookTracking and isBookTrackingEnabled functions
* **sync:** improve user feedback in sync dialog for missing spine
* **ci:** streamline commit-analyzer configuration in release setup [release]

### Maintenance

* **plugin:** small updates, add versioning
* **plugin:** rename files to fix crashes
* **ci:** update releaserc
* **network:** fix offline behavior
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **semantic-release:** release 1.0.1 - [skip ci on prod]
* **semantic-release:** release 1.0.2 - [skip ci on prod]
* **semantic-release:** release 1.0.3 - [skip ci on prod]
* **semantic-release:** release 1.0.4 - [skip ci on prod]
* **semantic-release:** release 1.0.5 - [skip ci on prod]
* **semantic-release:** release 1.1.0 - [skip ci on prod]
* **semantic-release:** release 1.1.1 - [skip ci on prod]
* **updater:** remove changelog from update confirmation dialog
* **ui:** remove duplicate version option
* **menu:** reorganize menu structure for improved usability
* **updater:** remove changelog from update confirmation dialog
* **ui:** remove duplicate version option
* **semantic-release:** release 2.0.0 - [skip ci on prod]
* **semantic-release:** release 3.0.0 - [skip ci on prod]
* add batch upload feature note to README
* **semantic-release:** release 3.1.0 - [skip ci on prod]
* **semantic-release:** release 3.2.0 - [skip ci on prod]
* **ci:** add pre-commit
* **semantic-release:** release 3.3.0 - [skip ci on prod]
* **git:** remove linting
* **semantic-release:** release 3.3.1 - [skip ci on prod]
* **ci:** remove comment stage
* **ci:** bump pre-commit version
* **ci:** limit semrel to only run on set commits / MRs
* **db:** add migrations
* **settings:** restructure settings
* **database:** add pending annotations queue for retrying failed uploads
* **database:** add function to delete pending ratings
* **all:** remove and simplify comments
* **documentation:** remove testing static files
* **documentation:** remove generated files
* **ci:** disable lychee
* **docs:** add index page
* **semantic-release:** release 3.4.0 - [skip ci on prod]
* **all:** delete some files
* **ci:** add zola workspace to variables
* **documentation:** use @ links
* **tests:** add tests
* **documentation:** add reference for the custom image
* **readme:** remove troubleshooting steps for easier maintenance
* update highlights and notes sync status to 'Currently not working'
* **auto-match:** streamline hash matching process and enhance logging for auto-acceptance
* **database:** add methods to save and retrieve hardcover user ID
* **api:** resolve merge conflict and improve error handling in getBookById and submitBookmark functions
* **database:** update schema version to 20 and adjust migration index
* **menu:** streamline sync triggers and reintroduce hardcover integration
* **formatting:** enforce formatting
* **readme:** add testing instructions and coverage artifact details
* **ci:** remove test stage and associated run-tests job from CI pipeline
* **ci:** trigger release [release]
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **ci:** add stuff [release]
* **semantic-release:** release 1.0.0 - [skip ci on prod]
* **changelog:** reset changelog [release]
* **semantic-release:** release 1.0.0 - [skip ci on prod]

### Other Changes

* initial rewrite
* add ci and files
* add releaserc
* progress on historical sync, broken
* first working implementation of historical sync
* add isbn to db, change reading session json. allow isbn matching
* add isbn extraction from api
* current progress
* fix sync for historical sessions with present books
* drop unused table
* record all the decimals
* fix session copy, add koreader title, id
* update format
* remove double version
* add docs
* Add small changelog to updater
* remove linting, add MR comment function
* fix(update, log): change path handling
* chore(db, settings): settings into database
* update ci
* Better annotation handling
* refactor(sync flow): resolve book_id first, then session/rating/annotations
* Fix shelf sync async tasks

### BREAKING CHANGES

* add auto-updater system with GitHub integration
* add auto-updater system with GitHub integration
* **release:** trigger major version bump [release]

## 3.4.0 (2026-02-22)

### Features

* **metadata:** add metadata parser
* **settings:** add new sync menu for ratings and notes
* **database:** update schema to version 9 and add book metadata sync functionality
* **api:** add submitRating function for personal book ratings
* **api:** add annotation support
* **database:** add annotation sync helpers for KOReader
* **notes:** add  color mapping, cfi generation, sync  for notes
* **rating:** enhance rating sync with live in-memory support and retry mechanism
* **rating:** respect user settings for rating sync and improve handling of deferred ratings
* **sync:** enhance session details view and improve pending uploads handling
* **settings:** rework clear cache to select entries to be cleared on category level
* **docs:** add documentation and zola support
* **settings:** sanitize server URL input and enhance connection test messages

### Bug Fixes

* **settings:** change upload strategy for notes
* **changelog:** change changelog match
* **rating:** delay keyboard display in rating dialog to prevent crashes on Linux
* **database:** update schema version and relax constraints for pending annotations and ratings
* **ci:** add workspace dir for zola
* **ci:** add submodul handling
* **documentation:** add sidebar template with table of contents, remove version picker
* **sync:** mark annotations as synced when CFI cannot be built
* **api:** improve error message formatting in extractErrorMessage function [release]

### Maintenance

* **ci:** remove comment stage
* **ci:** bump pre-commit version
* **ci:** limit semrel to only run on set commits / MRs
* **db:** add migrations
* **settings:** restructure settings
* **database:** add pending annotations queue for retrying failed uploads
* **database:** add function to delete pending ratings
* **all:** remove and simplify comments
* **documentation:** remove testing static files
* **documentation:** remove generated files
* **ci:** disable lychee
* **docs:** add index page
* **semantic-release:** release 3.4.0 - [skip ci on prod]

### Other Changes

* fix(update, log): change path handling
* chore(db, settings): settings into database

## 3.3.1 (2026-02-20)

### Bug Fixes

* **reading-session:** correct page retrieval method for EPUB format

### Maintenance

* **git:** remove linting
* **semantic-release:** release 3.3.1 - [skip ci on prod]

## 3.3.0 (2026-02-19)

### Features

* **sessions:** add support for pdf and archive-type formats

### Maintenance

* **ci:** add pre-commit
* **semantic-release:** release 3.3.0 - [skip ci on prod]

### Other Changes

* Add small changelog to updater
* remove linting, add MR comment function

## 3.2.0 (2026-02-16)

### Features

* **logging:** implement file-based logging with daily rotation and automatic cleanup
* **logging:** enhance file logging with initialization and closure handling

### Bug Fixes

* **database:** improve journal mode handling for better reliability

### Maintenance

* **semantic-release:** release 3.2.0 - [skip ci on prod]

## 3.1.0 (2026-02-16)

### Features

* **api:** add batch session upload endpoint with intelligent batching

### Bug Fixes

* **sync:** handle nil progress values in session processing and batch uploads
* **sync:** fallback to individual upload on 403 Forbidden

### Maintenance

* add batch upload feature note to README
* **semantic-release:** release 3.1.0 - [skip ci on prod]

### Other Changes

* add docs

## 3.0.0 (2026-02-16)

### Features

* add auto-updater system with GitHub integration

### Bug Fixes

* **updater:** handle HTTP redirects manually for KOReader compatibility
* **updater:** use correct lfs library path for KOReader
* **updater:** remove duplicate restart confirmation dialog
* **menu:** use text_func instead of text for dynamic pending count

### Maintenance

* **updater:** remove changelog from update confirmation dialog
* **ui:** remove duplicate version option
* **menu:** reorganize menu structure for improved usability
* **semantic-release:** release 3.0.0 - [skip ci on prod]

### Other Changes

* remove double version

### BREAKING CHANGES

* add auto-updater system with GitHub integration

## 2.0.0 (2026-02-16)

### Features

* add auto-updater system with GitHub integration

### Bug Fixes

* **updater:** handle HTTP redirects manually for KOReader compatibility
* **updater:** use correct lfs library path for KOReader
* **updater:** remove duplicate restart confirmation dialog

### Maintenance

* **updater:** remove changelog from update confirmation dialog
* **ui:** remove duplicate version option
* **semantic-release:** release 2.0.0 - [skip ci on prod]

### BREAKING CHANGES

* add auto-updater system with GitHub integration

## 1.1.1 (2026-02-15)

### Bug Fixes

* tag version in github

### Maintenance

* **semantic-release:** release 1.1.1 - [skip ci on prod]

## 1.1.0 (2026-02-15)

### Features

* log obfuscation

### Maintenance

* **semantic-release:** release 1.1.0 - [skip ci on prod]

## 1.0.5 (2026-02-15)

### Bug Fixes

* another ci

### Maintenance

* **semantic-release:** release 1.0.5 - [skip ci on prod]

## 1.0.4 (2026-02-15)

### Bug Fixes

* new ci

### Maintenance

* **semantic-release:** release 1.0.4 - [skip ci on prod]

## 1.0.3 (2026-02-15)

### Bug Fixes

* new ci

### Maintenance

* **semantic-release:** release 1.0.3 - [skip ci on prod]

## 1.0.2 (2026-02-15)

### Bug Fixes

* ci now allows addition?

### Maintenance

* **semantic-release:** release 1.0.2 - [skip ci on prod]

## 1.0.1 (2026-02-15)

### Bug Fixes

* ci file

### Maintenance

* **semantic-release:** release 1.0.1 - [skip ci on prod]

### Other Changes

* update format

## 1.0.0 (2026-02-15)

### Bug Fixes

* **network:** add missing options

### Maintenance

* **plugin:** small updates, add versioning
* **plugin:** rename files to fix crashes
* **ci:** update releaserc
* **network:** fix offline behavior
* **semantic-release:** release 1.0.0 - [skip ci on prod]

### Other Changes

* initial rewrite
* add ci and files
* add releaserc
* progress on historical sync, broken
* first working implementation of historical sync
* add isbn to db, change reading session json. allow isbn matching
* add isbn extraction from api
* current progress
* fix sync for historical sessions with present books
* drop unused table
* record all the decimals
* fix session copy, add koreader title, id

