## Purpose

Defines explicit, reviewable, recoverable photo-library changes for album archive and deletion, including simulation safeguards, stale-reference checks, partial failures, and idempotent recovery.

## ADDED Requirements

### Requirement: Album archive is explicit and failure-safe
The system SHALL let users choose a recent system album or create a new system album. A successful archive SHALL be visible in the photo library; an archive failure SHALL preserve the asset and its prior keep/delete state.

#### Scenario: Asset is added to an existing album
- **WHEN** the user confirms an accessible target album
- **THEN** the system adds the asset to that album and records archive success only after the photo-library change succeeds

#### Scenario: User creates a target album
- **WHEN** the user enters a valid new album name and confirms
- **THEN** the system creates the system album, adds the selected asset, and makes the album available as a recent target

#### Scenario: Target album disappears or permission changes
- **WHEN** the target album is unavailable when the archive executes
- **THEN** the asset remains preserved, no successful archive is recorded, and the user is asked to choose another target

### Requirement: All deletion candidates receive unified review
The system SHALL require a review page before any real deletion request. Review SHALL show candidate count, estimated space, source tasks, protection or favorite indicators, and excluded protected count, and SHALL allow any candidate to be removed.

#### Scenario: User edits the review list
- **WHEN** the user removes a candidate during unified review
- **THEN** that asset is not submitted for deletion and its task state remains recoverable

#### Scenario: User cancels review
- **WHEN** the user leaves or cancels deletion review
- **THEN** no real delete request occurs and all pending decisions remain reversible

### Requirement: Real deletion uses system confirmation
The system SHALL submit a real delete request only after app review confirmation and SHALL rely on the operating system's final confirmation. It SHALL not claim to bypass or replace Recently Deleted.

#### Scenario: User confirms app review
- **WHEN** the user confirms a non-empty validated review list in a real-mutation configuration
- **THEN** the system requests deletion through the photo library and allows the operating system to display final confirmation

#### Scenario: System confirmation is declined
- **WHEN** the user declines the operating system deletion confirmation
- **THEN** no candidate is recorded as successfully deleted and the review state remains recoverable

### Requirement: Mutations validate identity and report partial results
The system SHALL re-fetch candidate asset identifiers immediately before mutation, SHALL never substitute a missing asset, and SHALL record successful and failed identifiers separately so successful work is not repeated.

#### Scenario: Candidate becomes stale
- **WHEN** a reviewed asset no longer exists or is no longer accessible before submission
- **THEN** it is excluded from the request, reported as stale, and unrelated valid candidates continue

#### Scenario: Mutation partially fails
- **WHEN** only part of an archive or deletion batch succeeds
- **THEN** the result reports successful, failed, and stale counts separately, retains failed items for retry, and does not resubmit successful identifiers

#### Scenario: App terminates around mutation completion
- **WHEN** the app relaunches after a mutation was submitted but before its result was fully stored
- **THEN** the system reconciles the current photo library with the pending transaction before offering retry

### Requirement: Development mutation safety is deterministic
Debug and UI-test sessions SHALL use simulated archive and deletion by default. Real PhotoKit mutations in Debug SHALL require an explicit developer setting, while Release SHALL use the real mutation service.

#### Scenario: UI test confirms deletion
- **WHEN** an automated UI test completes deletion review
- **THEN** the simulated backend returns a deterministic result without changing the simulator or host photo library

#### Scenario: Debug real-mutation setting is off
- **WHEN** a developer confirms deletion in a normal Debug run without explicitly enabling real mutations
- **THEN** the system simulates the result and clearly identifies the non-destructive mode in developer-facing settings

#### Scenario: Release deletion is confirmed
- **WHEN** a release build submits a validated deletion request
- **THEN** the system uses the real photo-library mutation path and retains both app review and operating-system confirmation

