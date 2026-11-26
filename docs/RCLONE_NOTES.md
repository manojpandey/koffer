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
05 missing source (exit 3), 06 in-progress stats with `transferring`, then SIGINT, 07 resume after the interrupt.
