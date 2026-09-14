## Context

See `proposal.md` for motivation and `specs/` for observable behavior. The existing iOS 17 SwiftUI app has an `@Observable` main-actor `AppModel`, a single `PhotoLibraryServing` protocol, an actor-backed live PhotoKit scan, and basic Tasks, Albums, and Settings screens. It already handles full, limited, denied, and restricted access; cancellation of an in-memory scan task; local versus iCloud-only classification; expired screenshots; and long-video diagnosis.

The missing P0 flow crosses PhotoKit reads and writes, Vision analysis, durable workflow state, local notifications, and most feature screens. Real deletion is destructive and not fully testable on the simulator. The implementation must remain local-only, avoid third-party runtime dependencies, and preserve the existing authorization and classification behavior while expanding it.

## Goals / Non-Goals

**Goals:**

- Keep media reading, analysis, task generation, persistence, and mutations independently testable behind narrow protocols.
- Make every pending decision and mutation transaction recoverable and idempotent across app termination.
- Produce conservative, explainable recommendations from Apple on-device frameworks with a low-confidence no-recommendation outcome.
- Make simulator and UI-test flows deterministic without allowing an accidental real Debug deletion.
- Build all screens from standard SwiftUI navigation, lists, grouped forms, toolbars, sheets, confirmation dialogs, and semantic accessibility.

**Non-Goals:**

- Persisting or syncing media-derived content, embeddings, OCR, faces, filenames, or locations.
- Building a general machine-learning platform, remote feature service, telemetry pipeline, or extensible plugin architecture.
- Supporting background execution beyond the time and APIs iOS grants; persisted checkpoints provide recovery instead.
- Proving real-device PhotoKit behavior through simulator automation. Device acceptance remains a separate release gate.

## Decisions

### 1. Split library boundaries by responsibility

Introduce four narrow service boundaries and inject them into the application composition root:

- `PhotoLibraryReading`: authorization, asset descriptors, thumbnail requests, album reads, and library-change observation.
- `PhotoLibraryMutating`: album creation/addition and deletion requests with per-identifier outcomes.
- `PhotoAnalysisEngine`: duplicate/similar/burst grouping and supported recommendation signals from local media.
- `TaskRepository`: checkpoints, decisions, task records, transaction journals, settings, and aggregates.

`AppModel` remains the main-actor presentation coordinator but delegates scan and decision workflows to actor-isolated services. Model values crossing actor boundaries are immutable `Sendable` structs containing stable local identifiers and display-safe metadata.

Rationale: the current combined protocol is adequate for read-only diagnosis but would let destructive operations leak into previews and tests. Separate boundaries make non-destructive simulation explicit and keep UI code free of direct PhotoKit changes.

Alternative considered: one expanded `PhotoLibraryServing` protocol. Rejected because it couples long-running reads, analysis, and destructive writes and makes test doubles broad and error-prone.

### 2. Persist workflow records with SwiftData, never media content

Use a small SwiftData store with schema-versioned records equivalent to:

- scan checkpoint: scan id, scope, phase, processed stable identifiers or cursor data, counts, and timestamps;
- task record: type, ranked score components, status, ordered asset identifiers, ownership, and timestamps;
- decision record: asset identifier, decision, target album identifier when applicable, protection source, task id, and timestamps;
- mutation transaction: operation, requested identifiers, per-identifier state, submitted/completed timestamps, and recovery status;
- cleanup summary: aggregate action counts, estimated bytes, duration, and period;
- user settings: screenshot threshold, weekly-mode state, reminder choice/day, recent album identifiers, and Debug mutation preference where available.

Derived task candidates can be rebuilt from accessible identifiers and decisions. Thumbnails remain in the system image cache only and are never inserted into SwiftData. Clearing PhotoBox history deletes these app records but never performs a PhotoKit mutation.

Rationale: stable identifiers and a transaction journal are sufficient for relaunch recovery and idempotence while honoring the privacy boundary.

Alternative considered: JSON in `UserDefaults`. Rejected because multi-record reconciliation, schema evolution, queryable queues, and transaction state exceed a settings store's role.

### 3. Use a staged, cancellable scan and analysis pipeline

The scan coordinator is an actor that emits immutable snapshots through `AsyncStream`. Stages are authorization validation, descriptor enumeration, local-availability checks, lightweight candidate classification, bounded thumbnail analysis, task materialization, and completion. Each loop checks cancellation and writes a safe checkpoint only after a coherent batch.

The coordinator subscribes to photo-library changes. Added identifiers enter an incremental scan; removed identifiers are reconciled from tasks and decisions. A scope or permission change invalidates incompatible in-flight work and returns a recoverable state. iCloud-only assets remain visible as skipped/pending counts and never block local work.

Rationale: staged output preserves the current partial-result experience and avoids holding full-resolution assets or the entire analysis graph in memory.

Alternative considered: restart every scan from zero on launch or library change. Rejected because it violates recovery and scales poorly for large libraries.

### 4. Build conservative recommendations from verifiable local signals

Candidate construction uses PhotoKit metadata first:

- screenshots: system screenshot subtype plus configurable age threshold;
- bursts: PhotoKit burst identifiers, with short-time adjacency used only as a conservative fallback group;
- duplicate/similar candidates: nearby creation time and compatible dimensions narrow the comparison set before bounded thumbnails receive Vision Feature Print comparison;
- large videos: duration and available resource size estimates remain diagnosis-only.

Within a group, the analysis engine may use supported, reproducible signals such as favorite or reliable edited state, pixel dimensions, sharpness estimate, exposure clipping estimate, and subject framing when confidently available. It emits structured reason codes, not free-form model claims. Manual protection and favorite state outrank visual quality. A recommendation appears only when the winning margin and required evidence exceed fixed tested thresholds; otherwise no item is labeled best.

Rationale: pairwise/local group comparison is more defensible than an opaque universal quality score and provides UI reasons that correspond to actual computations.

Alternative considered: a custom Core ML model or cloud model. Rejected for P0 because it adds model validation, distribution, privacy, performance, and unsupported-explanation risk.

### 5. Represent decisions as a reversible state machine

One decision record owns the current asset state. Keep, delete candidate, archive, protect, and decide later are mutually replacing outcomes; archive and delete can never coexist. A lightweight undo journal stores the immediately previous record plus affected aggregates until the decision is superseded or its mutation succeeds.

Task ownership is assigned when an asset enters an in-progress task. Other tasks suppress that identifier until the task completes, pauses and releases it, or becomes invalid. Task completion, weekly-mode eligibility, and statistics are derived from decision and transaction results rather than visual navigation events.

Rationale: a single source of truth prevents counts, review lists, and task cards from diverging after undo or relaunch.

Alternative considered: independent sets for kept, deleted, archived, protected, and later identifiers. Rejected because contradictory membership and rollback become likely.

### 6. Journal and reconcile every PhotoKit mutation

Before a mutation, create a pending transaction and re-fetch exact stable identifiers. Mark missing identifiers stale, submit only valid identifiers, and update each result to succeeded or failed. On relaunch, reconcile any submitted-but-unfinished transaction with current PhotoKit state before enabling retry; retry includes failed identifiers only.

Archive executes immediately after explicit album choice because it is non-destructive, but its decision is not marked successful until PhotoKit commits. Deletion collects candidates in one review, then the live mutator invokes PhotoKit so iOS presents system confirmation. Successful deletion removes the pending decision from retry eligibility and the result continues to call space savings estimated until Recently Deleted is cleared.

Rationale: an explicit journal handles partial failures and the termination window without relying on an in-memory callback.

Alternative considered: optimistic success followed by best-effort correction. Rejected because it can duplicate mutations and misreport destructive outcomes.

### 7. Select mutation implementation at the composition root

The app composition root selects `SimulatedPhotoLibraryMutator` for UI tests and for Debug by default. A Debug-only developer setting may explicitly select the live mutator and is visually labeled. Release has no simulation toggle and selects the live mutator. UI tests pass launch arguments for deterministic authorization, scan fixtures, thumbnails, mutation results, and notification behavior.

Rationale: compile-configuration and launch-environment selection prevents a UI action from silently switching a test into destructive mode.

Alternative considered: one live service with a per-call `simulate` Boolean. Rejected because a misplaced argument can make an individual destructive call real.

### 8. Use native navigation and one unidirectional presentation state

`MainTabView` expands to Tasks, Albums, Statistics, and Settings. Each tab owns a `NavigationStack`; task destinations are value-driven routes so relaunch recovery can rebuild the correct screen from repository state. Standard sheets handle album selection and bounded inspectors; confirmation dialogs cover destructive choices; the unified delete review is a full destination rather than a transient alert.

The design system is limited to spacing constants, an eight-point maximum control radius, semantic status mapping, and reusable media thumbnail/action rows. Native fonts, grouped backgrounds, list/form sections, system blue, destructive red, SF Symbols, Dynamic Type, accessibility values, and `accessibilityReduceMotion` provide the Apple first-party character.

Rationale: platform components improve familiarity, accessibility behavior, and visual consistency with less custom layout risk.

Alternative considered: card-heavy custom dashboard and gesture-first decision UI. Rejected because it weakens discoverability, large-text behavior, and the requested Apple app style.

### 9. Keep notifications local and downstream of demonstrated value

The notification service is requested only after a meaningful initial cleanup and an explicit reminder choice. It replaces any prior PhotoBox weekly request with one calendar-based local notification for the selected weekday. Notification text is generic and contains no derived photo content.

Rationale: permission timing follows user value and avoids introducing remote infrastructure or private payload data.

Alternative considered: request notification permission during onboarding. Rejected because the benefit is not yet demonstrated and permission denial would be more likely.

## Risks / Trade-offs

- [Vision comparisons can be expensive on large libraries] -> Narrow candidates with metadata, analyze bounded thumbnails in batches, check cancellation, publish partial tasks, and measure 5k/20k/50k libraries separately.
- [Feature Print similarity is not semantic certainty] -> Use conservative thresholds, never label low-confidence output best, expose only computed reason codes, and keep every selection editable.
- [PhotoKit does not expose every file byte count or edit detail uniformly] -> Treat byte savings and edit recognition as estimates; omit unavailable reasons rather than infer them.
- [System deletion confirmation and partial PhotoKit failures cannot be fully automated on Simulator] -> Cover the transaction state machine and simulated UI flow automatically, then record real archive/delete behavior as UNVERIFIED until dedicated-device acceptance passes.
- [SwiftData migration adds persistence risk] -> Start with a versioned schema, store minimal primitives, add repository migration tests, and keep app-history reset separate from PhotoKit.
- [Library change events can race with decisions or mutations] -> Re-fetch identifiers at decision display and mutation boundaries, invalidate only affected records, and journal mutations before submission.
- [Four tabs and P01-P16 can produce inconsistent custom layouts] -> Compose a small set of native reusable rows and action bars, centralize semantic status tokens, and run screenshot/accessibility UI tests at compact and accessibility text sizes.

## Migration Plan

1. Introduce the repository schema and service protocols while adapting the current read-only scan behind `PhotoLibraryReading`; verify existing authorization and scan tests unchanged.
2. Add deterministic fixtures, simulated mutator, analysis engine, task generation, and state-machine unit tests before connecting new destinations.
3. Add the four-tab shell and P0 screens in vertical slices: diagnosis/task generation, similar and single decisions, queues/album archive, delete review/result, then weekly/statistics/settings.
4. Enable live album mutation behind the Debug developer switch and complete disposable-library device checks.
5. Enable live deletion only through the review path, complete system-confirmation and partial-failure device checks, then validate Release composition.
6. Rollback, if required before release, selects the existing diagnosis-only root and leaves the new local store unused; no rollback path deletes or mutates the system photo library.
