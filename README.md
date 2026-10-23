# Organize files by type

A conservative Windows file organizer: moves **top-level files only** into category folders, with a preview, confirmation, durable recovery journal and retryable undo. Subdirectories are never organized or deleted. Requires Windows PowerShell 5.1 and the two entrypoint files kept together; no modules or package installation are needed.

**Back up first. Use a standalone sorting inbox, not a project, application, game, synchronized workspace or system folder. Moving related files can break applications and relative links. Detection is a guardrail, not proof that a folder is safe. Run without administrator privileges.**

## Usage

From Command Prompt, with the organizer on your current directory or PATH:

```bat
OrganizeFilesByType.bat "D:\SortingInbox" /preview
OrganizeFilesByType.bat "D:\SortingInbox"
OrganizeFilesByType.bat "D:\SortingInbox" /y
OrganizeFilesByType.bat "D:\SortingInbox" /undo /y
OrganizeFilesByType.bat "D:\SortingInbox" /skipother /preview
```

Without `/y`, inspect the plan and type exactly `YES` to proceed. Anything else cancels. With no folder argument, the script asks for one; paste the path without surrounding quotes. Drag-and-drop is supported by Windows' ordinary batch-file association, but no automatic pause is added. Run from an existing terminal to see results reliably. `/help` or `/?` prints usage. Unknown arguments fail rather than silently changing behavior.

The PowerShell entrypoint avoids Command Prompt's argument expansion and is preferable for paths containing percent signs or other shell-sensitive characters:

```powershell
.\OrganizeFilesByType.ps1 -Path 'D:\SortingInbox' -Preview
.\OrganizeFilesByType.ps1 -Path 'D:\SortingInbox' -Auto -SkipOther
.\OrganizeFilesByType.ps1 -Path 'D:\SortingInbox' -Undo -Auto
```

PowerShell parameters: `-Path`, `-Auto`, `-Undo`, `-SkipOther`, `-Preview`. Batch equivalents: folder, `/y` (or `/yes`), `/undo` (or `/u`), `/skipother`, `/preview`. A preview makes no filesystem changes, including for undo. `-Auto` does not bypass safety guards. The batch launcher clears inherited legacy `ORG_*` control flags, disables delayed expansion, never uses `CALL`, and runs the adjacent `.ps1` with `-File`, not expression evaluation. It sets process-only execution-policy bypass; organizational policy can still prevent execution. Review downloaded scripts before running them.

## Categories and safeguards

Pictures, Video, Audio, Documents, Spreadsheets, Presentations, Data, Code, Archives, DiskImages, Installers, Fonts, Design, CAD and Shortcuts retain the original extension groups. Unknown extensions go to `Other` unless skipped; extensionless files go to `No extension`. Matching is case-insensitive. Existing destinations receive numbered names such as `report (1).txt`; both existing files and other planned destinations are reserved. Nothing is overwritten. Hidden files are included; organizer-reserved `.organize-files-*` entries are not moved. Empty category directories are intentionally retained on undo rather than risking deletion of user-owned folders.

The script refuses:

- Drive roots, UNC/device paths, the profile/application-data roots, Windows, Program Files, ProgramData and the organizer's own directory tree.
- Recognizable project markers in the target or its ancestors, stopping before the profile root: `.git`, package manifests, Python/Rust/Go/Java/.NET build markers, virtual environments, `node_modules` and other common markers (see `Assert-SafeRoot` for the exact list).
- Executables, DLLs and .NET application markers directly in the target. This deliberately blocks even a downloads folder containing `.exe` installers; move standalone installer files manually instead of disabling the protection. Other supported installer formats remain categorized.
- Reparse points (including junctions/symlinks) on the target's ancestry or on any file/category/journal path used by an operation. Directories cannot be used in place of files or categories.
- A new organize run while an active recovery journal exists. Finish recovery first, or deliberately archive that journal **outside** the inbox after accepting the changes and keeping a backup. Completed `.undone.csv` journals do not block future runs.

An exclusive, delete-on-close lock prevents overlapping organizer/undo writers in the same folder. Preview does not acquire a lock and may become stale.

## Recovery and undo

Before any move, the **entire plan** (canonical original and destination paths, category, schema version and SHA-256 content hashes) is written to a unique `.csv.pending` file with write-through and a disk flush. Only after it is closed and renamed to `.csv` do moves begin. The source hash is checked again immediately before its move. Each move is a non-overwriting, same-volume file rename. If any move fails, the run stops and keeps the full intent journal, including entries not yet moved. This is intentional: journals describe intended operations, not a claim that every move completed.

Run `/undo /y` against the **same folder at the same location** after an interruption. Undo validates the entire selected CSV before moving anything: exact schema, version/hash format, unique paths, canonical immediate-root originals and immediate known-category destinations. Traversal, alternate streams, relative/external paths, reserved names and file/directory substitutions are rejected. Legacy CSVs from the original hybrid script are not accepted: they lack the safety metadata. Preserve them and recover manually from backups after verifying every path; do not rewrite or fabricate safety hashes to make an old journal pass.

For each validated intent:

| Original | Category destination | Action |
| --- | --- | --- |
| Absent | Present, original hash matches | Restore without overwriting |
| Present, original hash matches | Absent | Already restored or never moved; leave untouched |
| Present | Present | Conflict, even if bytes match; leave both untouched |
| Absent | Absent | Unresolved; manual recovery/backup required |
| Changed content at either remaining location | Any | Unresolved; never replace changed content |

Independent safe rows can still be restored when another row conflicts. The journal remains active if anything is unresolved; resolve conflicts without deleting valuable data and run undo again. Rows already restored are recognized on retry. Only fully resolved journals are renamed `.undone.csv`. If multiple active journals have been introduced externally, undo selects the lexically newest filename; inspect its printed plan before accepting it.

An orphan `.csv.pending` file means publication of that journal did not finish; this implementation makes **no moves from that pending plan**. Keep it while investigating. It is not imported by automatic undo. Do not assume it belongs to some unrelated failed run. No recovery or organizer log is a backup of your files.

Exit codes: `0` success/no work/preview/cancel; `1` safety refusal, invalid journal or operation failure; `2` undo left unresolved rows and can be retried. Watch both the code and printed summary.

## Limits and threat model

- Local ordinary folders on a local Windows filesystem only; tests exercise NTFS. Long paths and unusual filesystem providers are not supported. No cross-volume copying, recursion, directory moves or automatic folder cleanup.
- SHA-256 covers the file's default data stream, not alternate streams, security descriptors or metadata. Hashing costs an extra full read before movement and during recovery. Identical replacement bytes cannot be distinguished from the original file.
- This is not a security boundary against a hostile process modifying files, links, mounts or journals concurrently. Checks reduce accidental damage, but path validation and rename are not one atomic kernel transaction. Close editors/downloaders, pause sync software, and restrict inbox write access. The lock coordinates this tool, not arbitrary applications.
- Journals are validated but not cryptographically authenticated. Someone with write access can forge a valid, in-scope recovery instruction. Do not use journals supplied by strangers. Never open machine journals in a spreadsheet: treat them as text, not formulas. Journal paths are absolute and begin with a drive letter, including when a filename begins with `=`.
- Process termination is tested using a real killed child process, followed by byte-for-byte recovery. Write-through and flushing improve durability but cannot guarantee recovery after hardware failure, power loss, filesystem corruption, unavailable storage or malicious changes. Keep independent backups.
- Project/application detection is intentionally conservative and incomplete. Standalone executable markers can produce false positives; unknown layouts can evade detection. There is no safety-override switch.
- Moving the inbox invalidates absolute journal paths. Changed files, deleted files, external rearrangements and old journal formats need manual handling. Keep unresolved journals private and intact.

## Tests

Run from the project directory using **Windows PowerShell 5.1**, not PowerShell 7:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Integration.Tests.ps1
```

The dependency-free suite creates unique disposable fixture trees, starts real organizer processes, exercises real file handles/junctions, kills a child mid-move, and removes its fixtures afterward. By default fixtures live in the current account's local Hermes scratch tree; set `ORG_TEST_TEMP` to a dedicated writable scratch directory to use another location. Do **not** set it to the repository. Only its newly created unique test subdirectory is cleaned up. Use `-Case 'killed*'`, for example, to select a case. No real user documents are used as fixtures. GitHub Actions runs the same suite on a Windows runner with an isolated scratch directory and does not upload artifacts.

## Privacy and licensing

Recovery CSVs contain private absolute paths. `.gitignore` excludes organizer files, CSVs, logs, journals, temporary files, test output/artifacts and dumps. Never force-add them. Publish only the small, reviewed source/documentation/configuration inventory, not device diagnostics or original user files.

No license is supplied and no new license grant is made. Ownership and permission to redistribute should be confirmed with the author before adding a license.
