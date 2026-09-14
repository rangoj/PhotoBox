## Purpose

Let people organize accessible photos by familiar collections and months while retaining real progress, bounded daily sessions, and recoverable deletion review.

## ADDED Requirements

### Requirement: Photo-first dark home and navigation
The home SHALL use the approved Stitch A01 dark composition (screen ed74c7ed04284ad0ad6d845c69755fcc in project 11208455012423558853), with only PhotoBox as its header, four photo entries, descending years and months, and four previews per month. The shell SHALL expose Organize, Albums, and My. Secondary screens SHALL hide the tab bar. My SHALL retain statistics, settings, unfinished work, and pending deletion recovery.

#### Scenario: User returns to the home
- **WHEN** a user leaves a collection and returns
- **THEN** the home retains its scroll position and reflects saved decisions

#### Scenario: User launches normally
- **WHEN** no pending mutation result needs recovery
- **THEN** the app opens the home, with unfinished work reachable without automatic weekly navigation

### Requirement: Truthful inventory and month progress
The home SHALL include accessible photos, Live Photos, and panoramas, including cloud-only assets, and exclude videos. It SHALL derive progress from all effective persisted decisions, including submitted decisions, using existing decision semantics. Each month SHALL show either no progress, a processed fraction, or a completion check. Missing dates SHALL form an undated section. Missing thumbnails SHALL use stable placeholders without network downloads.

#### Scenario: Cloud-only and local photos share a month
- **WHEN** two local photos and one cloud-only photo are accessible
- **THEN** the month reports three photos while new organization batches contain only eligible local photos

#### Scenario: Decision is undone
- **WHEN** a persisted decision is removed or restored by undo
- **THEN** home progress reflects the current effective decision exactly once per accessible asset

### Requirement: Stable daily collection batches
The home SHALL support historical month-and-day, the last thirty natural days including today, random date then batch selection, and a selected month. Batches SHALL contain only local unprocessed photos not owned by other active tasks, SHALL never cross a day, and SHALL contain at most fifty photos. Undated photos SHALL form singleton batches. Existing batches SHALL retain their order and progress across entrances, rescans, and launches.

#### Scenario: A large day is split
- **WHEN** a day contains 56 or 120 eligible photos
- **THEN** it forms 28+28 or 40+40+40 balanced batches respectively

#### Scenario: Another entrance reaches the same day
- **WHEN** a user starts via a month and later enters via Recent
- **THEN** the eligible unfinished batch is resumed without a duplicate task or reset cursor

#### Scenario: Assets change after a batch starts
- **WHEN** new photos arrive or existing photos become inaccessible
- **THEN** the saved order is retained, inaccessible photos are not decided, and new photos enter separate batches

### Requirement: Existing safe processing remains reachable
Collection sessions SHALL reuse existing decision actions and persistence. Duplicate entry SHALL list existing duplicate and similar tasks. Date batches SHALL not contribute invented deletion-space estimates to diagnosis. A completed batch with deletion candidates SHALL open existing review; a batch without candidates SHALL open existing results. Completing results SHALL return home.

#### Scenario: User marks a photo for deletion
- **WHEN** the batch completes with a deletion candidate
- **THEN** review is reachable and no deletion success is claimed before the existing system mutation succeeds

### Requirement: Recoverable and accessible states
The home SHALL represent loading, empty library, limited access, cancellation, failure, completed collection, and no eligible local photos. It SHALL preserve existing permission and scan recovery actions. Text and controls SHALL remain reachable at 375-point width and accessibility text sizes, with meaningful VoiceOver labels and at least 44-point touch targets.

#### Scenario: Scanning fails
- **WHEN** a scan fails before inventory becomes available
- **THEN** the home presents a retry action and does not claim the library is empty or fully organized

#### Scenario: A completed month is tapped
- **WHEN** all accessible photos in a month have effective decisions
- **THEN** the app reports completion without resetting those decisions
