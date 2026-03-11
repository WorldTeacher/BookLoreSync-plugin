# [3.7.0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/compare/3.6.1...3.7.0) (2026-03-11)


### Bug Fixes

* **sync:** improve shelf book synchronization and filename generation ([d9f6701](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/d9f670164f453180c3053515fcc8e700b0b18555)), closes [#23](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/issues/23)


### Features

* **sync:** enhance shelf synchronization with improved subprocess handling and user feedback ([118ca0f](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/118ca0fbcce02413937e210d110d05bd9efb65de))

## [3.6.1](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/compare/3.6.0...3.6.1) (2026-03-10)


### Bug Fixes

* **gestures:** sync now gesture also asks for wifi to be enabled ([5c1d431](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/5c1d43133bed8138ed54cd6687c587c79b7738f1))

# [3.6.0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/compare/3.5.1...3.6.0) (2026-03-10)


### Bug Fixes

* **annotations:** save to both now actually uploads to both locations ([bbe0018](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/bbe00181950e9a7286342a14a4886923602cf354))
* **ci:** add lua-tests stage to CI pipeline for improved testing coverage ([15f558b](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/15f558b1817416a7cb76356bc4f398eea86f7738))
* **ci:** add missing stages to CI pipeline configuration ([2364711](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/2364711c69e2d318d72c0c40b69108fbab5f85a2))
* **ci:** comment out unused butler configuration in CI pipeline ([cfd2c46](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/cfd2c46cbb33b0623d6e4b677320a4fa06a4fefe))
* **ci:** remove unused pipeline stages from configuration ([a1eacbe](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a1eacbee5479d8cd1657bc87e59f4e3fee8429c4))
* **ci:** rename lua-tests to lua-check and update testing commands ([9c5e1a9](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/9c5e1a9c01de6e509a7e9a5bde4cf04b782e5bdd))
* **ci:** restore butler configuration and remove unused lua-check stage ([5968d92](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/5968d925c26b692e357eaafb3c39b35d1ca8c6d9))
* **ci:** update butler rules to ensure proper execution based on GITLAB_TOKEN ([f783f97](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/f783f97a8c49f863d7f9becdf64aa1ef9733e9bf))
* **ci:** update lua-check to use luajit and adjust script for compatibility ([3fc5235](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/3fc52357b898ec80866495ec056b3140088ac2aa))
* **docs:** standardize punctuation in documentation for clarity ([556d424](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/556d4242dff3e00c393874c2830c207fd62e48e7))
* **isbn:** update ISBN lookup to use searchBooksByIsbn and handle exact match scoring ([14b4bd1](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/14b4bd119ca96d57bc210e0dc042b96ccb1e20b9))
* **network:** fix bug in ask to enable wifi, fixes crash related to networking by using networkmanager ([e0b0f26](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/e0b0f26682753e11282013d058556adf4f3219f8)), closes [#18](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/issues/18) [#25](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/issues/25)


### Features

* **api:** add ISBN lookup functionality to retrieve book ID ([8bfe89c](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/8bfe89c18263d44a5a7623b261f0df5abeb62cec))
* **isbn:** extract ISBN from KOReader doc settings and use as fallback for book lookup ([5389cd8](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/5389cd88fbd739f7e0fd4e1ec9c4a39232434d39))

## [3.5.1](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/compare/3.5.0...3.5.1) (2026-03-09)


### Bug Fixes

* **ci:** change pipeline to always run ([0a4fa45](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/0a4fa45dc4aaf74a377af1f006d4a62b47c4a948))
* **match:** show popup when hash lookup finds no match in Booklore [release] ([0d6e73e](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/0d6e73e82e8e9075fd3984205e60eae3dd579c16))

# [3.5.0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/compare/3.4.1...3.5.0) (2026-03-08)


### Features

* **release:** trigger semrel [release] ([95ebf03](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/95ebf0308a7c257919dcc121695dc22bc715b712))

# 1.0.0 (2026-03-08)


### Bug Fixes

* another ci ([a02981c](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a02981cc51775781dcd0f97542c7da42246256da))
* **api:** improve error message formatting in extractErrorMessage function [release] ([5c8db41](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/5c8db41d5b5423ba71b5cee7a249dcd9ac724b80))
* **changelog:** change changelog match ([aabf190](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/aabf190123fcbf000253844f13428197576f60e0))
* ci file ([7befd0c](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/7befd0c9e2258bc64cc7eba3fd30b2b65f43f7c2))
* ci now allows addition? ([b279e43](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/b279e437d47f43d54ee82550b876f078129acaf5))
* **ci:** add submodul handling ([eaecd0d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/eaecd0dd3c1d9eea0941206d613189d5ec62fb62))
* **ci:** add workspace dir for zola ([f328261](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/f3282619530feece35f1c761e1a28ce2742bbf0c))
* **ci:** streamline commit-analyzer configuration in release setup [release] ([78449f4](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/78449f4ec25c2c70f461560603fbd1d5a5e27ec1))
* **database:** improve error handling in setBookTracking and isBookTrackingEnabled functions ([44a6a94](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/44a6a94ba6efab99868c5cf1558d4b4e8ae282c0))
* **database:** improve journal mode handling for better reliability ([bd55a63](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/bd55a63f6b21b69326c89b3bfbff3bfe7a7a4720))
* **database:** update schema version and relax constraints for pending annotations and ratings ([78719bf](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/78719bfef347c0b77a098b1e1c7c9cd1b8f239ec))
* **documentation:** add sidebar template with table of contents, remove version picker ([cdf3ab2](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/cdf3ab23993dc6c65e54b283b1a106ea151fa6d8))
* **hardcover:** use self.server_url instead of self.booklore_url in fetchAndStoreHardcoverIds ([21005a6](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/21005a69cee0f1a5836e927aae78700899175e19))
* **logging:** enhance logging for batch upload sessions with book ID details ([08c839c](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/08c839ce369372ea7c20f636df48d7c1debd744f))
* **main:** re-remove extended_sync ([92a9b67](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/92a9b67ef5cc32abc3dd4a345545f451b1fc8511))
* **menu:** add function to integrate items into the main menu ([5cdc571](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/5cdc571b83e779beb9da1d65eb54dcb2641ca35e))
* **menu:** update menu item text for fetching Hardcover Book IDs ([73bbfd3](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/73bbfd3b221239fb43198b6fd79f2cd5f40dc784))
* **menu:** use text_func instead of text for dynamic pending count ([2df8e5d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/2df8e5de99def2b33a56fdd0d5aec773dd64a868))
* **network:** add missing options ([ae1c624](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/ae1c62437425fb5d9cbbde123ead1b990f626909))
* new ci ([23c8a9f](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/23c8a9fb5c6169d2f68188859c08a9b4cc1f1789))
* new ci ([529250f](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/529250f98668d0bcd581205959dd8e48dc890674))
* **pop-up:** show synced / skipped for other areas ([14d0abb](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/14d0abbadc2d471792f1cefe8323e22f61222882))
* **rating:** delay keyboard display in rating dialog to prevent crashes on Linux ([89188f4](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/89188f4147ca5cec86c04a4a5af6ef2150fab455))
* **reading-session:** correct page retrieval method for EPUB format ([97adae7](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/97adae7891d5745a94f910da5c392982f750b16d))
* **settings:** change upload strategy for notes ([8e7bbe0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/8e7bbe0b262b26b2b5c6f238e95febe6025aa39a))
* **shelf-sync:** read KOReader home_dir for download dir detection ([a6cf6d0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a6cf6d02316a0ce753469586602dda163eac8da4))
* **sync:** fallback to individual upload on 403 Forbidden ([33e3f50](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/33e3f500e530002c614ae4474c6a1441013b93c8))
* **sync:** handle nil progress values in session processing and batch uploads ([59f37ed](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/59f37ede5b195180aa0b9d8538565088cf3bc563))
* **sync:** improve user feedback in sync dialog for missing spine ([90c5a6c](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/90c5a6ccfcff894ddca79fad85bee0654f298a65))
* **sync:** mark annotations as synced when CFI cannot be built ([c8e0025](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/c8e002592d9afc0cf86cfaa12db91bb044b28303))
* tag version in github ([8159028](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/81590283895dd7999938f8e761be840a2cdebc7b))
* **update, log:** change path handling ([94e3541](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/94e3541ea5f39644ad9d9a90e2d709712b560165))
* **updater:** handle HTTP redirects manually for KOReader compatibility ([6dfac88](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/6dfac88b4d5f44b3bb15f5f216df01cf9c4b94b6))
* **updater:** handle HTTP redirects manually for KOReader compatibility ([54a4b54](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/54a4b54aaed747f0386cf12f15b79ac09f7addf0))
* **updater:** remove duplicate restart confirmation dialog ([76e458d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/76e458dc734aa0e62aedd69ab724936580ae42f1))
* **updater:** remove duplicate restart confirmation dialog ([42f1ee1](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/42f1ee1af1acb091cca40f7996a539617308dc02))
* **updater:** use correct lfs library path for KOReader ([a577d43](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a577d438dc78d0ad338b5b38732e81a460108eae))
* **updater:** use correct lfs library path for KOReader ([672475d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/672475df681d1f3d6940692a63589fbd590a1745))


### Features

* add auto-updater system with GitHub integration ([33ad50a](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/33ad50a61a85c9c12652c4d17677f039daf1b74e))
* add auto-updater system with GitHub integration ([a64659d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a64659d85c4135d2dbddcb0a0ece6fabf16e905f))
* add file manager hold menu items (sync annotations, match book, sync rating) ([3151842](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/3151842e4470df7c6e074d342163953114134c6a))
* add file manager hold menu items (sync annotations, match book, sync rating) ([f14c971](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/f14c97139d888f8e77456dec1c8464d52d148034))
* add Manual Matching placeholder to Import Reading History menu ([cd02555](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/cd025554077438332dcf7fa48f9d77a2f7c2bdbf))
* **annotations:** add 'Both' destination and PDF mock CFI support ([b47b8a2](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/b47b8a22565e438dc900755925fd02f57f3bfef2))
* **api:** add annotation support ([7f3328a](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/7f3328a4c7cb9adb2de5ca97c6c1a2a730d186cb))
* **api:** add batch session upload endpoint with intelligent batching ([d951ded](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/d951ded34253b078bd34cbbee81c4e7718766b89))
* **api:** add submitRating function for personal book ratings ([53eb9f5](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/53eb9f57113790b85bd180a47af770e51be776ab))
* **bookmarks:** calculate bookmark cfi ([1dc2550](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/1dc2550ff9fd0cfcdf54fafc64b62425763331a6))
* **bookmarks:** sync bookmarks to Booklore via api/v1/bookmarks ([556b075](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/556b075cf900f3a4001b06ee0576c606c0f05e05))
* **database:** add annotation sync helpers for KOReader ([16c7ae8](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/16c7ae85698613b0f10a6a7b503e1b1c5f5731bb))
* **database:** add hardcover_id column to book_cache for rating sync ([a5a8f98](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a5a8f9803b8cab1d34e602ce03f9630b80da9b18))
* **database:** update schema to version 9 and add book metadata sync functionality ([1bcd707](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/1bcd707c75ce65a18f67a99fd453b2f36a5c6921))
* **db:** add hardcover_id column to book_cache (migration 16) ([e442bfd](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/e442bfd535b71ee7a663c8f36a897cf3cfbdadaf))
* **deletion:** notify Booklore when books are deleted from file manager ([b734c33](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/b734c33fb248573400da321d31fd8c7c2f43a1c9))
* **docs:** add documentation and zola support ([60013cf](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/60013cffdbfeb1df2e5aae76ebfbd342ccbbad24))
* **docs:** add versioned docs with version selector ([9bdf8a5](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/9bdf8a525210b45bbea27f55dbce2e14ad6bd2e1))
* **hardcover:** add debug menu with 'Request book metadata from BookLore' action ([9517ba5](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/9517ba596f085a34db1ff3fb5c2e9eaa0104f532))
* **hardcover:** implement Hardcover API client and integrate with BookloreSync for rating and book search ([d6a9bda](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/d6a9bdad6918fbdaea0eccaf739ef43f163fa743))
* log obfuscation ([a3f28e6](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a3f28e6c6dd6f25b69a8275ff7ba99baeb845d8d))
* **logging:** enhance file logging with initialization and closure handling ([b6510e5](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/b6510e56e69209b1c0501bfccb6cac69b5c78fe9))
* **logging:** implement file-based logging with daily rotation and automatic cleanup ([6ce67cc](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/6ce67ccd60c4d3a52ba85d41d978dc3a8367660f))
* **metadata:** add metadata parser ([17cea86](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/17cea864364f453939482183ae745c2a56648eaf))
* **metadata:** enhance bookmark extraction from DocSettings and improve filtering logic ([931cde8](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/931cde8b3c685325d95725994fb98d7d5cb30bca))
* **notes:** add  color mapping, cfi generation, sync  for notes ([d044964](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/d0449645bec39449ba8eabdb48975f01b4f30089))
* probe by-hash endpoint in test connection ([421b3cb](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/421b3cb66f7311a42f22a819739c55bc60114609))
* **rating:** enhance rating sync with live in-memory support and retry mechanism ([a31c8a0](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a31c8a090166192960041a7069187f4a42bd51a3))
* **rating:** respect user settings for rating sync and improve handling of deferred ratings ([439d5df](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/439d5dfd311ce8c885a3cea71839d009a5f2cbef))
* **release:** trigger major version bump [release] ([693f0ef](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/693f0eff23b83ece128dc73a0864fbaf89939ca0))
* **resume:** add 5min cooldown, deferred wake sync, onNetworkConnected ([833b7e6](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/833b7e69780a4e8d777afd13614a061e76dc8f6e))
* **sessions:** add support for pdf and archive-type formats ([0ee7f07](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/0ee7f071ba59b01301b3162b91ca41cf5efce844))
* **settings:** add hardcover token configuration and rating sync options ([6de7d53](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/6de7d530f025621d5e0a6e1a8a450b109d198b3b))
* **settings:** add new sync menu for ratings and notes ([aeaa2cf](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/aeaa2cf374ed34d7e20f6e7e81b3c950d9e43ba6))
* **settings:** add settiings export for debug ([32a63e3](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/32a63e30714abc801934f6d9908601ec05f9844a))
* **settings:** rework clear cache to select entries to be cleared on category level ([391f2c7](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/391f2c7583e6f0a2f076a10061d6b41420207d43))
* **settings:** sanitize server URL input and enhance connection test messages ([126f93e](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/126f93e8347f3967ddef6837a434f445680fe2b0))
* **shelf-sync:** pull books from Booklore shelf with bidirectional sync ([efd25b1](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/efd25b19673a0c748af014be4682a717f08db75d))
* **shelf-sync:** smart download dir detection + shelf name/dir config UI ([8bd79ad](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/8bd79add3cca09fa3f4ceec1cb2d82bb98ed6622))
* **skip-book:** per-book tracking toggle via file manager long-press ([a8fee10](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/a8fee10326941e1f0319d7224a94f503e9a8262a))
* **sync:** add bookmarks sync configuration and toggle functionality ([fbec927](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/fbec927ff2bd424f5f07f9ccc9fff18f09d2e44a))
* **sync:** add bookmarks sync functionality and update related methods; add check for existing annotations ([2d0c56d](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/2d0c56d5a74ff99bc5781f2c9037bf77f97cd72f))
* **sync:** enhance book synchronization with interactive matching and improved UI dialogs ([0f7722a](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/0f7722acc89ec730bcbafb0018a5e8c6a45e9978))
* **sync:** enhance session details view and improve pending uploads handling ([24130e3](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/24130e34f0fea73c08897878a5d30e2e8a1741ac))
* **sync:** implement hardcover rating sync with token validation and fallback search ([ff19876](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/ff19876bc8ab40451620a1130109eed0e4c01413))
* **test:** Add unit tests for BookloreSync and Updater helper functions ([8a9ff97](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/8a9ff9765c8e7bacb31a82352a446351b4398b21))
* **ui:** Merge branch 'skip-book' ([900683a](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/900683a88abb3475276ae203dc3f9ce07cc15d68))
* **ui:** register file manager hold menu actions for syncing annotations, matching book, and syncing rating ([96654d7](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/96654d70cb187dcfda2dbbdd3b01244d65dfbcd6))
* **wifi:** add user confirmation for enabling WiFi before syncing ([9eefec6](https://gitlab.worldteacher.dev/wt-booklore/booklore-koreader-plugin/commit/9eefec69c69e286cb263d775bb515c835d0ed33e))


### BREAKING CHANGES

* **release:** trigger a major release bump.
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
