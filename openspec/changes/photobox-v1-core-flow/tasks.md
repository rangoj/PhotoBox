## 1. Baseline and Persistent Domain Model

- [x] 1.1 Record the current Debug build and focused unit-test baseline using the configured `.ai-workflow/config.yml` commands, and verify all pre-existing tests pass before behavior changes.
- [x] 1.2 Add immutable `Sendable` domain models for asset descriptors, candidate groups, recommendation reasons, cleanup tasks, decisions, mutation outcomes, and summaries, and verify focused unit tests cover equality, protected-state precedence, and estimated-space aggregation.
- [x] 1.3 Add the versioned SwiftData schema and `TaskRepository` implementation for checkpoints, tasks, decisions, mutation journals, settings, and summaries, and verify an in-memory repository round-trip test stores no prohibited media-derived fields.
- [x] 1.4 Implement repository reconciliation and app-history clearing, and verify tests remove stale identifiers and local history without invoking any photo-library mutation.

## 2. Photo Library Reading and Analysis

- [x] 2.1 Split the existing read service into `PhotoLibraryReading` plus immutable descriptors while preserving authorization and local/iCloud behavior, and verify all existing authorization, cancellation, screenshot, video, and availability tests remain green.
- [x] 2.2 Add resumable staged scan coordination with checkpoints and explicit cancel/resume/restart behavior, and verify controlled-stream tests prove cancelled scans cannot publish stale results after a replacement scan.
- [x] 2.3 Observe accessible-library additions, removals, and scope changes and merge them incrementally, and verify unit tests retain unrelated decisions while invalidating only removed identifiers.
- [x] 2.4 Add bounded thumbnail loading and metadata candidate narrowing for screenshots, bursts, duplicate/similar photos, and large-video diagnosis, and verify tests exclude iCloud-only and insufficient-evidence assets from unsupported recommendations.
- [x] 2.5 Implement the local `PhotoAnalysisEngine` using structured Vision/Core Image reason codes and conservative confidence thresholds, and verify fixture tests produce a supported recommendation, protected-item override, and low-confidence no-best outcome.

## 3. Task Generation and Decision State

- [x] 3.1 Implement diagnosis summaries and deterministic task ranking from confidence, risk, space, time, freshness, and skip history, and verify unit tests prioritize low-risk work over a larger high-risk task.
- [x] 3.2 Implement exclusive per-asset task ownership plus pause, resume, skip, complete, and relaunch recovery, and verify repository-backed tests prevent one identifier from entering two in-progress tasks.
- [x] 3.3 Implement the single-decision state machine for keep, delete candidate, archive, protect, and decide later, and verify tests cover mutual exclusion, aggregate changes, and decision replacement.
- [x] 3.4 Add the pending-decision undo journal and post-submission boundary, and verify tests restore task position and counts before submission but direct completed deletion recovery to Recently Deleted.
- [x] 3.5 Integrate repository-backed scan, task, decision, and routing state into `AppModel`, and verify main-actor tests restore the correct task and pending decisions after model reconstruction.

## 4. Safe Photo Library Mutations

- [x] 4.1 Define `PhotoLibraryMutating` and implement a deterministic simulated mutator with configurable success, stale, cancellation, and partial-failure outcomes, and verify unit tests never call a live PhotoKit API.
- [x] 4.2 Implement mutation journaling, preflight identifier validation, per-identifier results, retry filtering, and relaunch reconciliation, and verify tests do not resubmit successful identifiers after partial failure or interrupted completion.
- [x] 4.3 Implement live system-album listing, creation, and asset addition, and verify protocol-level tests cover missing target albums while disposable-library device acceptance remains explicitly tracked.
- [x] 4.4 Implement live PhotoKit deletion only through a validated non-empty request, and verify composition tests prove Debug and UI tests select simulation by default while Release selects the live mutator.
- [x] 4.5 Add the Debug-only explicit real-mutation setting and developer-facing mode label, and verify a Debug launch without opt-in cannot construct the live mutator.

## 5. Apple-Style Application Shell and Diagnosis

- [x] 5.1 Reduce the design layer to native spacing, semantic status colors, system-blue primary actions, destructive styling, and reusable rows with at most eight-point radii, and verify previews or screenshots contain no decorative gradients, nested cards, or custom substitutes for standard controls.
- [x] 5.2 Expand `MainTabView` to Tasks, Albums, Statistics, and Settings with value-driven navigation destinations, and verify a UI test finds all four simplified-Chinese tabs and restores a persisted route safely.
- [x] 5.3 Update permission and scan screens with truthful scope, partial progress, cancellation, resume/restart, limited-access, failure, and healthy-library states, and verify UI tests cover full, limited, denied, restricted, cancelled, and empty fixtures.
- [x] 5.4 Build the diagnosis report and ranked task inbox with count, reason, time, risk, current storage, and estimated reclaimable-space semantics, and verify deterministic UI fixtures show correct task order and Recently Deleted guidance.

## 6. Comparison, Decisions, Queues, and Archive UI

- [x] 6.1 Build reusable paged media-thumbnail and metadata views with cancellation and media-type badges, and verify loading, unavailable, video, Live Photo, panorama, favorite, edited, and protected fixtures do not shift or overlap controls.
- [x] 6.2 Build the similar/burst comparison flow with editable preselection, zoom/inspection, verifiable reasons, low-confidence state, cumulative counts, and automatic next-group navigation, and verify a UI test changes the recommended selection before completing a group.
- [x] 6.3 Build the single-photo decision flow with visible labeled keep, delete, archive, protect, and decide-later controls plus undo, and verify the full action set works without swipe gestures in UI tests.
- [x] 6.4 Build system-album selection, recent targets, new-album creation, and archive failure recovery, and verify simulated UI tests keep the asset and request reselection after a missing-target result.
- [x] 6.5 Build Albums, Decide Later, and Protected screens with unprotect and repeated-deferral behavior, and verify relaunch UI fixtures preserve queue membership without automatically creating delete candidates.

## 7. Delete Review, Results, Weekly Inbox, and Settings

- [x] 7.1 Build unified delete review with source tasks, protection/favorite indicators, excluded count, candidate removal, estimated space, cancel, and final confirmation, and verify UI tests prove cancellation never calls the mutator.
- [x] 7.2 Build cleanup results for success, partial failure, stale assets, retryable failures, archive/protect/defer counts, duration, and estimated space, and verify a UI test retries only unresolved identifiers.
- [x] 7.3 Implement meaningful-cleanup transition and weekly-inbox generation from new, expired-screenshot, unfinished, and deferred work, and verify tests enforce the five-minute default bound and truthful tidy empty state.
- [x] 7.4 Build Statistics with aggregate organization metrics, estimated-value labels, full-rescan entry, and confirmed history clearing, and verify clearing history leaves simulated photo and album inventories unchanged.
- [x] 7.5 Add the local weekly reminder service and Settings controls for opt-in, weekday replacement, disablement, permissions, privacy, screenshot threshold, and Debug mutation mode, and verify notification tests schedule at most one generic content-free request only after meaningful cleanup.

## 8. Accessibility and Automated End-to-End Coverage

- [x] 8.1 Add stable accessibility identifiers, labels, hints, values, traits, and logical reading order to every critical control and state, and verify an accessibility audit UI test finds no unlabeled actionable element in the P0 flow.
- [x] 8.2 Verify Dynamic Type at an accessibility size and Reduce Motion for permission, task, comparison, decision, review, result, and queue screens using UI tests or captured simulator evidence with no clipped text or occluded actions.
- [x] 8.3 Add a deterministic UI-test fixture that completes permission, partial scan, diagnosis, similar comparison, all five decision types, archive, delete review, simulated system result, result page, and weekly inbox, and verify it passes on the configured iPhone 17 simulator.
- [x] 8.4 Add focused UI tests for empty, limited, stale, archive-failure, delete-partial-failure, relaunch-recovery, and no-paywall paths, and verify each failure exposes a valid recovery action.

## 9. Final Verification and Device Acceptance

- [x] 9.1 Run the configured Debug and Release simulator builds plus all Swift Testing unit tests, and record PASS/FAIL evidence with the exact simulator and derived-data paths.
- [x] 9.2 Run the configured XCTest UI suite on iPhone 17, iOS 26.3.1, and record PASS/FAIL evidence for the deterministic non-destructive P0 flow.
- [x] 9.3 Run read-only `reviewer` and `test_reviewer` passes on the final diff, address actionable findings, and record the completed reviewer identities without treating acknowledgement as test evidence. (Euler, Goodall; actionable findings addressed in batch recovery, task reconciliation, candidate ownership, and mutation recovery.)
- [x] 9.4 Validate `photobox-v1-core-flow` with OpenSpec and run `./Scripts/ai-workflow validate --route spec --openspec-change photobox-v1-core-flow` with harness and reviewer evidence, and verify the validator exits successfully or reports each remaining UNVERIFIED item explicitly.
- [ ] 9.5 On a dedicated device with a disposable library, verify limited/full permission changes, live album creation/archive, iOS deletion confirmation, Recently Deleted wording, partial failure/relaunch recovery, and 5k/20k/50k performance; until executed, report these items as UNVERIFIED rather than PASS.
