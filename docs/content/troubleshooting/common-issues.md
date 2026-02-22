+++
title = "Common Issues"
description = "Solutions to the most frequently encountered problems."
weight = 1
+++

# Common Issues

---

## Plugin not appearing in the Tools menu

**Symptom:** The BookLore Sync entry is missing from **Tools**.

**Causes and fixes:**

1. **Wrong directory** — The plugin folder must be placed directly in the plugins directory, not inside a subdirectory:
   ```
   ✓  {your_koreader_installation}/plugins/bookloresync.koplugin/main.lua
   ✗  {your_koreader_installation}/plugins/some-folder/bookloresync.koplugin/main.lua
   ```

2. **Wrong folder name** — The folder must be named exactly `bookloresync.koplugin`. KOReader identifies plugins by the `.koplugin` suffix.

3. **KOReader not restarted** — A restart is required after installing the plugin. Use **Menu → Exit → Restart**.

4. **Lua syntax error** — If a file in the plugin is corrupted (e.g., from a bad download), KOReader will skip the plugin silently. Check the log:
   ```bash
   grep -i "booklore\|koplugin" /tmp/koreader.log
   ```

---

## Connection test fails

**Symptom:** Tapping **Test Connection** shows an error.

**Step 1 — Verify the server is running:**

```bash
curl http://your-server:6060/api/health
# Expected response: {"status":"ok"}
```

If this fails, the server is down or the address is wrong.

**Step 2 — Check the URL format:**

- Use `http://` or `https://` — not just the hostname.
- Do not add a trailing slash.
- For local network addresses, make sure the device and server are on the same network.

**Step 3 — Check credentials:**

- The username and password must match a valid BookLore user account and/or KOReader account, depending on what fails.
- Re-enter them via **Settings → Authentication → Configure KOReader Account**. or **Settings → Authentication → Configure BookLore Account**

**Step 4 — Check firewall / reverse proxy:**

If BookLore is behind a reverse proxy, confirm the `/api/koreader/` path is not blocked or rewritten.

---

## Sessions are not syncing

**Symptom:** You read a book but no sessions appear in BookLore.

**Check 1 — Plugin is enabled:**

Open **Tools → BookLore Sync** and confirm the plugin is enabled. If the toggle is off, sessions are not recorded at all.

**Check 2 — View pending count:**

**Tools → BookLore Sync → Settings → Manage Sessions → View Details**

If the pending count is rising, sessions are being saved but not uploaded. Move on to Check 3.

If the pending count stays at 0, sessions may be failing validation. Move on to Check 4.

**Check 3 — Try a manual sync:**

**Tools → BookLore Sync → Sync Now**

If this also fails, check the KOReader log for network errors:

```bash
grep BookloreSync /tmp/koreader.log | grep -i "error\|fail\|timeout"
```

**Check 4 — Validate session thresholds:**

Sessions are discarded silently if they fail validation. If you are reading for less than 30 seconds (default minimum duration) or fewer than 5 pages (default minimum pages), sessions will not be saved.

Check your thresholds:

**Tools → BookLore Sync → Settings → Sync Settings → Session Settings → Minimum Duration**

**Check 5 — Manual Sync Only mode:**

If **Manual Sync Only** is enabled, sessions will accumulate in the queue until you tap **Sync Now** manually.

**Tools → BookLore Sync → Settings → Preferences** → confirm Manual Sync Only is off.

---

## Book not found on server

**Symptom:** Sessions are saved locally (pending count goes up) but fail to upload with a "book not found" error.

This means the book's MD5 fingerprint does not match any book in your BookLore library.

**Fixes:**

- Make sure the book file in KOReader is the same file as the one in your BookLore library (not a different edition or conversion).
- If you converted the file (e.g., MOBI → EPUB), the hash will differ. Add the converted version to BookLore.
- The book may not yet have been added to BookLore. Add it to the server, then retry the sync.

---

## "bad argument #1 to 'floor'" error

**Cause:** KOReader loaded a stale version of the plugin code from a previous session (e.g., after an update or edit without a full restart).

**Fix:** Restart KOReader completely — do not just wake from sleep.

---

## Annotations not appearing in BookLore

**Symptom:** Highlights or notes are not showing up in BookLore after a sync.

**Check 1 — BookLore credentials:**

Extended features (ratings, annotations) use Bearer token authentication via the **BookLore Account** credentials. Make sure these are configured:

**Settings → Authentication → Configure BookLore Account**

**Check 2 — Format compatibility:**

In-book annotations with EPUB CFI are only supported for EPUB files. For PDFs and comics, switch to "In BookLore" mode:

**Settings → Annotations → Notes destination: In BookLore**

**Check 3 — Upload strategy:**

If upload strategy is set to "Upload on read complete", annotations are only synced when progress reaches 99%+. Switch to "Upload on session end" to sync after every session.

**Check 4 — Deduplication:**

If you believe an annotation was never uploaded but the plugin shows it as already synced, inspect the `synced_annotations` table in the database. See [Database](/troubleshooting/database/).

---

## Ratings not syncing

**Symptom:** KOReader star ratings are not appearing in BookLore.

- Confirm **Enable rating sync** is toggled on in **Settings → Rating**.
- Confirm **BookLore Account** credentials are set.
- If using "KOReader scaled" mode, confirm the book has a star rating set in KOReader (check the book info panel).
- If using "Select at complete" mode, confirm the book is at ≥99% progress and that you selected a rating when the dialog appeared.
