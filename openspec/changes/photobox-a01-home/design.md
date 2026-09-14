## Context

See proposal.md for motivation. Existing AppModel owns scan descriptors, repository-backed tasks and decisions, routing and bounded thumbnails. CleanupTask is encoded as a payload in SwiftData, so an additive task type needs no new store entity. Existing pendingDecisions excludes submitted archive records and is insufficient for month progress.

## Goals / Non-Goals

Goals: a usable A01, source-correct sessions, progress recovery, and the approved three-tab shell. Non-goals: redesigning B/C flows, changing PhotoKit networking or mutation policy, full A02/A03 implementation, and automatic deletion.

## Decisions

- Add pure CleanupHomeProjection and DateBatchPlanner, keeping grouping and batching out of SwiftUI. Projection receives accessible descriptors and all effective decisions. Use the Gregorian calendar in the device timezone, injectable for boundary tests.
- CleanupHomeSource has onThisDay, recent, random, month(year:month:), and undated cases. CleanupHomeMonth exposes id, optional year/month, assetIDs, previewAssetIDs, processedCount, isComplete, and source. Projection exposes months, photos, and photos(for:now:calendar:).
- DateBatchPlanner.plan(source:descriptors:tasks:decisions:now:calendar:randomIndex:) returns DateBatchPlan(task:newTasks:notice:). Select existing eligible dateBatch work first, otherwise create balanced batches for the chosen day with deterministic photo order (creation date then identifier). Persist all splits together before navigation; random selects a date uniformly then a batch uniformly. Home-prefixed task IDs keep scan regeneration from invalidating them.
- Add CleanupTaskType.dateBatch and filter it out of diagnosis estimates. Existing serialized types/routes remain readable. No second persistence engine or copied photo data is introduced.
- AppModel exposes homeProjection, homeNotice, and startHomeCollection; reads all decisions alongside pendingDecisions, updates after scans/decisions/undo, and adapts the existing task routes. Loading and unavailable states use the existing authorization/scan state. Entry is disabled during initial enumeration, and any later recovery validates current descriptors before decisions.
- MainTabView hosts A01 and existing Albums; minimal My rows link to Statistics, Settings, unfinished tasks, review, and legacy diagnostics/weekly work where relevant. Normal restoration starts at home except existing pending results. Existing explicit UI fixture routes remain supported.
- Use local dark tokens (#121316 background, #e3e2e6 primary text, #8b91a0 secondary text, #aac7ff accent), native SF Symbols and zero tracking. Four 64-point covers and a four-column month preview grid keep the first month visible. Accessibility sizes allow entry labels and month metadata to wrap without shrinking.
- Reuse BoundedThumbnailLoader, loading only visible covers and retaining identity through async completion. Production photos come from PhotoKit; deterministic UI fixtures use bundled local images. No thumbnail network-policy changes.
- Existing decision actions retain their semantics. On a completed date batch, pending deletes lead to existing review; all-keep/archive/protect/later batches use existing results. Result completion returns home. Existing unfinished tasks remain available in My.

## Risks / Trade-offs

- Overlapping legacy tasks: enforce current ownership and decisions before constructing a session; never let a stale cursor decide an asset owned elsewhere.
- Changed authorization: mask the old home inventory until a replacement scan succeeds; preserve saved batch identities while skipping unavailable members.
- Large libraries: project metadata once per relevant state change; render months lazily and load bounded thumbnails only for visible rows.
- UI regression breadth: migrate navigation helpers and old landing assertions while retaining underlying permission, mutation, statistics and settings acceptance coverage.

## Migration Plan

Implement additively in the existing codex branch and retain the user's dirty-worktree base. Preserve persisted batches as immutable membership snapshots; reconcile eligibility at entry. Validate old JSON fixtures and existing repository tests. Rollback can restore the old home presentation without changing the system photo library.
