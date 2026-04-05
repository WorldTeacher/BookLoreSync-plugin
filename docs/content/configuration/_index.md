+++
title = "Configuration"
description = "All configuration options for the BookLore Sync plugin."
sort_by = "weight"
weight = 20
template = "section.html"

[extra]
hide_page_list = true
+++

<div class="section-cards">

  <a class="section-card" href="authentication/">
    <div class="section-card__icon">🔑</div>
    <div class="section-card__body">
      <div class="section-card__title">Connection Setup</div>
      <div class="section-card__desc">Configure your BookLore server URL and login credentials.</div>
    </div>
  </a>

  <a class="section-card" href="session-tracking/">
    <div class="section-card__icon">⚙️</div>
    <div class="section-card__body">
      <div class="section-card__title">What to Sync</div>
      <div class="section-card__desc">Configure reading sessions, progress sync, ratings, annotations, and bookmarks.</div>
    </div>
  </a>

  <a class="section-card" href="manage-sessions/">
    <div class="section-card__icon">🗂️</div>
    <div class="section-card__body">
      <div class="section-card__title">Sync & Cache</div>
      <div class="section-card__desc">Manually sync pending data, inspect queue state, resolve unmatched books, and clear local caches.</div>
    </div>
  </a>

  <a class="section-card" href="import-history/">
    <div class="section-card__icon">📥</div>
    <div class="section-card__body">
      <div class="section-card__title">Import & Matching</div>
      <div class="section-card__desc">Extract and match historical reading sessions from KOReader's statistics database.</div>
    </div>
  </a>

  <a class="section-card" href="hardcover/">
    <div class="section-card__icon">🎯</div>
    <div class="section-card__body">
      <div class="section-card__title">Hardcover</div>
      <div class="section-card__desc">Configure Hardcover.app integration for rating sync and book ID management.</div>
    </div>
  </a>

  <a class="section-card" href="preferences/">
    <div class="section-card__icon">🔧</div>
    <div class="section-card__body">
      <div class="section-card__title">Appearance & Diagnostics</div>
      <div class="section-card__desc">Configure notifications, logging, export, and plugin naming.</div>
    </div>
  </a>

</div>

---

## Main menu order

Current top-level order under **Tools → BookLore Sync**:

1. **Enable Sync**
2. **Connection Setup**
3. **What to Sync**
4. **Sync Behavior**
5. **Sync & Cache**
6. **Shelf Sync**
7. **Import & Matching**
8. **Integrations**
9. **Appearance & Diagnostics**
10. **About & Updates**
