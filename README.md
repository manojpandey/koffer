# Koffer

Koffer (Dutch for "suitcase") is a small macOS menu bar app that backs a folder up to OneDrive. It wraps the excellent `rclone` and starts on its own when you plug in your external disk.

## What it does, and the promises it keeps

- **One way only: disk to cloud.** Koffer never changes anything on your disk, unless you ask it to apply deletions you made in the cloud (see below), and even then it only moves files to the Trash.
- **Nothing in the cloud is hard-deleted.** Files you remove or overwrite on the disk are moved into a dated `_removed` folder (for example `onedrive:_Archive_removed/2026-11-26`), not destroyed.
- **Renames are cheap.** If you rename or move a file, Koffer does a server-side move instead of uploading it again.
- **It refuses to run on an empty or missing source.** If the disk is not there, or the folder looks empty, Koffer stops and tells you rather than guessing.

### Files you delete in the cloud

Your disk is the master copy, so normally anything missing in the cloud is uploaded again. But if you delete files in the cloud copy yourself (say, in the OneDrive website), Koffer notices before the next backup and asks instead of quietly putting them back. After every clean backup it remembers what is in the cloud; next time it compares. If files are gone from the cloud but unchanged on your disk, it holds the backup (automatic ones too) and shows a card with three choices: **Delete from this disk** (it checks each file again and moves it to the Trash, never deletes it outright), **Put them back** in the cloud, or **Decide later**. Files you changed on the disk since are simply backed up again. When a large part of the backup is missing, Koffer only offers to put it back: that usually means a folder was moved or deleted by mistake.

## Requirements

- macOS 14 or newer
- Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) `rclone` (`brew install rclone`) with a configured OneDrive remote (`rclone config`)

## Install

```sh
./scripts/install.sh
```

This builds the app, copies it to `/Applications` (or `~/Applications`), and opens it. Look for the suitcase icon in your menu bar. macOS will ask for permission to send notifications and to read removable disks. Say yes to both.

## First run: try the test job

Koffer ships with a small built-in test job: a folder called `Koffer Test` in your home folder, backed up to `onedrive:_koffer_test`. Start there before you trust it with anything real.

1. Open the menu bar icon and run the test job.
2. Add a file, rename one, delete one, and run it again. Watch what shows up as New, Moved and Removed.
3. Try stopping a run part-way, the way an unplugged disk would, and see that Koffer pauses cleanly and picks up next time.
4. Check `onedrive:_koffer_test_removed` to see your deleted file waiting in its dated folder.

## Adding a real job

Edit `~/Library/Application Support/Koffer/config.json`. A complete example lives in [`config/config.example.json`](config/config.example.json). Each job has a source folder, an rclone destination, a `removedRoot` for kept files, and optionally a `requiredVolume` and `autoSyncOnMount`.

- `neverSync`: path fragments (case-insensitive) that can never be a job source or sit inside one.
- `privatePaths`: rules like "anything with `Private Papers` in its path must never go to `onedrive:`". Koffer refuses to run a job that breaks a rule.

Use "What will change?" on a new job first. Automatic runs only start after you have looked at a preview.

If you keep a private job list, save it as `config/config.local.json` (gitignored). `install.sh` copies it into place on a fresh install.

## Where things live

- Logs: `~/Library/Logs/Koffer`
- Settings and history: `~/Library/Application Support/Koffer`

## Good to know

- Keep the lid open, or use power plus an external display, or the Mac will sleep mid-backup.
- The first big run can take many hours. OneDrive may throttle you; Koffer shows when that happens and carries on.
- The app is ad-hoc signed, so macOS may ask for permissions again after you rebuild it.
- If your OneDrive login expires, Koffer shows "Sign in again". Click it, finish signing in in your browser, and Koffer carries on.

## Development

```sh
swift build
swift test
./scripts/build.sh   # makes build/Koffer.app
```

Three targets:

- `KofferCore`: the engine, models, history and formatting (Foundation only)
- `Koffer`: the menu bar app (SwiftUI and AppKit)
- `KofferCoreTests`: XCTest, including rclone integration tests

CI runs on GitHub Actions (`macos-15`): build, test, bundle, and upload the zipped app. The module contract is in [`docs/CONTRACT.md`](docs/CONTRACT.md).

## Uninstall

```sh
./scripts/uninstall.sh
```

This removes the app and leaves your settings, history and logs where they are.
