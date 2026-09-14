## Why

PhotoBox currently diagnoses photo-library access, local availability, expired screenshots, and large videos, but it stops before users can complete the P0 cleanup workflow promised by the PRD. This change turns the diagnosis prototype into a trustworthy, persistent, end-to-end iPhone cleanup experience while retaining explicit user control over every PhotoKit mutation.

## What Changes

- Extend scanning to produce conservative duplicate, similar-photo, burst, expired-screenshot, and weekly-inbox candidates while keeping large videos diagnostic-only.
- Generate ranked cleanup tasks with reasons, risk, estimated time, and estimated reclaimable space; persist progress so tasks can pause, resume, skip, and survive relaunch.
- Add similar-group comparison and single-photo decision flows for keep, delete candidate, archive, protect, and decide later, including undo before submission.
- Add system-album selection and creation, protected and decide-later queues, and a unified delete review.
- Add PhotoKit archive/delete execution with stale-asset validation, partial-failure reporting, idempotent recovery, and iOS system confirmation for real deletion.
- Add a cleanup result, four-tab navigation (Tasks, Albums, Stats, Settings), weekly incremental inbox, aggregate statistics, and an optional local weekly reminder.
- Align all P0 screens with restrained Apple first-party visual conventions: native navigation, grouped surfaces, system colors and symbols, Dynamic Type, VoiceOver, and reduced-motion support.
- Add deterministic demo and UI-test data plus a simulated mutation backend. Debug builds use simulation unless a developer explicitly enables real PhotoKit mutations; Release builds use the real backend.
- Keep all analysis and decision data local. Do not persist image content, filenames, locations, OCR text, feature vectors, or reversible media fingerprints.
- Exclude StoreKit/paywalls, screenshot OCR or semantic classification, sensitive-content detection, remote analytics, video compression, cloud services, iPad-specific layouts, and English localization from this P0 change.

## Capabilities

### New Capabilities

- `library-scan`: Authorization-aware full and incremental scanning, local/iCloud classification, candidate discovery, progress, cancellation, and resumable diagnosis.
- `cleanup-tasks`: Ranked cleanup tasks, diagnosis summaries, similar/burst recommendations, task exclusivity, task lifecycle, and result aggregates.
- `photo-decisions`: User decisions, undo, archive targeting, protection, decide-later behavior, and local persistence across relaunches.
- `photo-mutations`: Safe PhotoKit album and deletion mutations, simulated debug execution, unified delete review, stale-asset checks, partial failures, and recovery.
- `weekly-inbox`: Incremental weekly work generation, progress, aggregate statistics, empty state, and user-controlled local reminders.
- `apple-style-interface`: P01-P16 information architecture and native iPhone UI behavior with simplified-Chinese accessibility support.

### Modified Capabilities

None. The repository has no existing OpenSpec capability baselines.

## Impact

- Production code: `PhotoBox/App`, `PhotoBox/Models`, `PhotoBox/Services`, `PhotoBox/Features`, `PhotoBox/Design`, and the app entry point.
- Tests: focused Swift Testing coverage for ranking, recommendation, decisions, persistence, recovery, and mutation results; XCTest UI coverage for the complete simulated P0 flow and accessibility identifiers.
- Frameworks: Photos/PhotosUI remain the system library boundary; Vision and Core Image provide on-device comparison signals; SwiftData stores identifiers and aggregate workflow state; UserNotifications provides local reminders.
- Runtime behavior: PhotoKit authorization, scan cancellation, persistence, album changes, and destructive deletion remain sensitive. Simulator validation uses deterministic simulation; real archive/delete acceptance requires a dedicated test device and a disposable photo library.
- Compatibility: iPhone portrait, iOS 17 or later, simplified Chinese. No third-party runtime dependency or remote service is introduced.
