## Why

The approved A01 design organizes the library around photo collections and months. The current diagnosis dashboard cannot open these collections or report their progress.

## What Changes

- Replace the primary dashboard with the approved dark A01 screen and real accessible-library thumbnails.
- Change the shell to Organize, Albums, and My; keep existing statistics, settings, unfinished work, and deletion recovery reachable.
- Add stable, resumable, day-bounded collection batches and truthful month progress, including cloud-only photos in the displayed inventory.
- Reuse the existing decision, comparison, review, and result screens; add a minimal duplicate/similar task list.
- This change supersedes the four-tab/dashboard presentation and automatic weekly landing in the unarchived photobox-v1-core-flow change. Its mutation safety and existing decision semantics continue to apply.

## Capabilities

### New Capabilities
- `cleanup-home`: Dark collection-based home, three-tab navigation, library projection, persistent date batches, and recovery.

### Modified Capabilities
None of the prior change's capabilities have been archived into main specs yet.

## Impact

SwiftUI home and navigation, AppModel orchestration, CleanupTaskType, task planning and diagnosis filtering, deterministic fixtures, and unit/UI tests. No new third-party dependencies or PhotoKit network policy changes. User approved this scope and requested implementation in the current workspace on 2026-09-14.
