# Changelog

What changed in Koffer, newest first. Koffer backs a folder on your Mac (or an external disk) up to the cloud,
one way, from the menu bar. Nothing in the cloud is ever hard-deleted: removed or replaced files go to a dated
`_removed` folder.

## 0.4.0 — Big folders (27 Nov 2026)

- **"What will change?" shows what it's doing.** Listing files, comparing N of M, matching moved files, the file
  being compared and the time so far, with a **Stop** button. Stopping a preview changes nothing.
- **Every preview writes its own log** to `~/Library/Logs/Koffer/<backup>_preview_<date>.log`.
- **Much lighter checks after the first clean backup.** Moved and renamed folders are matched by name, size and
  date instead of reading file contents. The first check of a big folder still compares contents, and says so.
- **No repeated work.** "Back up now" within 10 minutes of a preview reuses it, as long as nothing changed in
  between (same folders, disk not unplugged). Automatic backups always check for themselves.
- **Faster OneDrive scans** for Koffer's own cloud listings, used when the backup is most of the drive.

## 0.3.0 — Deleted in the cloud (27 Nov 2026)

- **Deletions in the cloud can flow back to the disk, after you decide.** If backed-up files were deleted in the
  cloud and are unchanged on the disk, the next backup pauses and asks: move them to the Trash on this disk, put
  them back in the cloud, or decide later. Automatic backups wait for your answer.
- **Guardrail:** if a large part of the folder disappears from the cloud at once, Koffer only offers to put it back.
- **Update Koffer from Settings.** Shows the version, checks GitHub, downloads, builds, swaps the app and restarts.
  If anything fails, nothing is replaced and the update log says why.
- **Confirmations are asked inside the panel.** System dialogs closed the menu bar panel when they were answered.

## 0.2.0 — Everything through the panel (26 Nov 2026)

- **No Terminal needed.** "Install rclone" (via Homebrew, or a direct download from rclone.org) and "Sign in again"
  are buttons in the panel.
- **Connection line** with the cloud's free space, and the route of each backup: local folder → cloud folder.
- **New backup window.** Pick a folder on this Mac, browse your cloud folders, create a new one, name the backup.
- **A list of backups** with a status icon and when each last ran. Right-click or "…" for Back up now,
  What will change?, Switch on/off, Show in Finder and Forget this backup (nothing is deleted anywhere).
- **Monochrome design:** system colours only, no gradients, colour reserved for warnings. New graphite app icon.
- **Builds with only the Command Line Tools,** no Xcode needed.

## 0.1.0 — First version (26 Nov 2026)

- **Menu bar app** wrapping `rclone sync` with `--track-renames` (moves happen server-side, no re-upload) and
  `--backup-dir` (removed or replaced files are kept in a dated `_removed` folder).
- **Starts on its own** when the backup's disk is plugged in, after you've approved one preview.
- **Progress, notifications and history:** progress, speed and time left; notifications when a backup starts,
  finishes or needs you; the last 20 runs with their logs.
- **Safety checks before every run:**
  - refuses to run on a missing or empty source;
  - checks free space before uploading;
  - honours folders that must never be backed up, and private folders that must never reach a given cloud;
  - keeps the Mac awake while backing up;
  - pauses cleanly if the disk is unplugged or the internet drops, and resumes next time.
- **Your own backups live in a local settings file,** never in this repository.
