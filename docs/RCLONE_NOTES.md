# What real rclone output looks like (v1.71, --use-json-log --stats 1s --log-level INFO)

One JSON object per line on **stderr**. Fields: `time`, `level` (`info`/`notice`/`warning`/`error`), `msg`, optional `object`, `objectType`, `size`, `skipped`, `stats`.

Per-file lines (level info), `object` = path relative to the sync root:
- `"msg":"Copied (new)"` -> New upload
- `"msg":"Copied (replaced existing)"` -> Replaced
- `"msg":"Moved (server-side) to: A/new/path.jpg"`, `object` = OLD path -> Moved (from --track-renames)
- `"msg":"Renamed from \"A/old/path.jpg\""`, `object` = NEW path -> companion line for the same move; do not double count
- `"msg":"Moved into backup dir"` -> Removed (kept in the removed folder). With --backup-dir this is what a delete or an overwrite looks like.
- `"msg":"Moved (server-side)"` with no "to:" can accompany a backup-dir move; do not count it as a rename.
- `"Removing directory"`, `"Set directory modification time ..."`, `"Making map for --track-renames"`: ignore.

Stats lines: any line with a `stats` object (level info every --stats interval, level notice at exit). Keys:
`bytes`, `totalBytes`, `transfers`, `totalTransfers`, `checks`, `totalChecks`, `speed` (bytes/s), `eta` (seconds or null),
`elapsedTime`, `errors`, `deletes`, `deletedDirs`, `renames`, `serverSideMoves`, `serverSideMoveBytes`, `fatalError`, `retryError`, `listed`,
and while files are in flight `transferring: [{name, bytes, size, percentage, speed, eta}]`.
Authoritative counters at the end of a run: uploaded = `transfers`, moved = `renames`, removed = `deletes`, errors = `errors`.
Assert tests against the numbers in the fixture's own final stats object.

Dry run (`--dry-run`): level notice lines with a `skipped` field and usually `size`:
- `"skipped":"copy"` -> would upload (`object` = path). A path that also appears with `move into backup dir` is a replacement, otherwise new.
- `"skipped":"move to A/new/path.jpg"`, `object` = old path -> would move
- `"skipped":"move into backup dir"` -> would remove (or the old version of a replaced file; do not list those twice)
- `"skipped":"remove directory"`, `"skipped":"set directory modification time"`: ignore.

Errors and exits:
- Missing source: `"error reading source root directory: directory not found"`, then `"not deleting files as there were IO errors"`, retried 3 times, exit code 3. rclone does NOT delete when the source cannot be read.
- SIGINT: `"Signal received: interrupt"`, `"Removing failed copy"`, `"Exiting..."`; partial uploads are cleaned up and a re-run continues where it stopped (fixtures 06 and 07).
- Exit codes: 0 ok, 1 uncategorised error, 2 usage, 3 directory not found, 4 file not found, 5 temporary error, 6 less serious errors, 7 fatal error, 8 transfer limit.
- OneDrive throttling: lines mentioning `429`, `Too Many Requests`, `throttl`, or `pacer: low level retry`.
- Expired login: lines mentioning `invalid_grant`, `couldn't fetch token`, `token expired`, `AADSTS`, or `unauthenticated`.
- `rclone about onedrive: --json` prints `{"total":..., "used":..., "free":..., "trashed":...}` on stdout (keys may be missing).
- `rclone size <remote:path> --json` prints `{"count":N,"bytes":N,"sizeless":0}`; exit 3 if the directory does not exist (treat as 0 bytes).

Fixtures in Tests/KofferCoreTests/Fixtures (paths inside them are from a Linux scratch machine):
01 initial sync, 02 dry run of rename + delete + modify + new, 03 the same for real, 04 nothing to do,
05 missing source (exit 3), 06 in-progress stats with `transferring`, then SIGINT, 07 resume after the interrupt,
08 a dry run (`--track-renames`, default hash strategy) of a renamed folder whose cloud copy has other modification times.

## v0.4: big folders (checked with rclone v1.71.2 on local scratch folders)

What a dry run reports while it works (`--dry-run --use-json-log --stats 1s`):
- Stats lines arrive every interval during a dry run too (at level `notice` here), with `listed` (entries listed so far,
  both sides together, folders included: 312 files on each side gave `"listed":626`), `checks` / `totalChecks`
  (pairs compared; `totalChecks` grows while listing goes on and again when renames are matched: 310 -> 324), and,
  while files are being compared, `"checking":["A/big_12.bin", ...]` as plain strings (not objects like
  `transferring`). The key is absent when nothing is being checked. The text in `msg` shows the state per file
  (`A/big_12.bin: checking` while comparing a pair, `: renaming` while hashing a destination file for the rename map).
- Where the time goes on the first check of a big folder:
  1. A file on both sides with the same size but another modification time is hashed on both sides (the whole local
     file is read). It shows up in `checking`, and as `"skipped":"update modification time"` in a dry run (a real run
     logs "Updated modification time in destination" and fixes the cloud's date, so the next check is quick).
     A dry run never fixes them, so repeated previews before the first real backup stay slow.
  2. `--track-renames` with the default `hash` strategy hashes every unmatched destination file to build its map
     ("Making map for --track-renames" ... "Finished making map"; `checking` lists them as `renaming`). On OneDrive the
     cloud hashes come from the server; on a local destination they are read.
  3. Then every unmatched source file is hashed to find its partner. During this phase `checks == totalChecks` and
     `checking` is empty: the stats show nothing for several seconds (5 s for 12 x 200 MB here). The UI says
     "Matching moved files…" then.
- Bytes read (rchar of the rclone process), 12 x 200 MB renamed folder, modification times already equal:
  hash strategy 5.0 GB (both sides local here), `--track-renames-strategy modtime,leaf` 600 bytes. Both found the same
  12 `"skipped":"move to ..."` lines, the dry run and the real sync alike.
- `modtime,leaf` while the cloud copy still has other modification times: the renamed files are NOT matched
  (12 `copy` + 12 `move into backup dir` instead of 12 moves). So Koffer uses it only after a clean backup with
  this version (a manifest exists), which means rclone has set the cloud dates.
- `--track-renames-strategy` takes `hash`, `modtime`, `leaf`, comma-separated (default "hash").
- `--onedrive-delta` is a global flag; rclone accepts it on any command, and on a non-OneDrive path it does nothing
  (`lsjson <local> -R --onedrive-delta` lists normally, exit 0). Per `rclone help backend onedrive`, the delta API
  only works at the drive's root: for a folder it walks the whole drive and drops the rest, so it is a big win when the
  backup is most of the drive and a loss when it is a small part. Koffer uses it only for its own `lsjson -R` and skips
  it when the last record says the backup is less than half of what the drive holds.
