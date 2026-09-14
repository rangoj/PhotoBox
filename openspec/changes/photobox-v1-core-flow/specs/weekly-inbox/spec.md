## Purpose

Defines the post-cleanup weekly inbox, truthful progress and empty states, aggregate local statistics, and optional user-controlled local reminder behavior.

## ADDED Requirements

### Requirement: Meaningful cleanup enables weekly mode
The system SHALL enter weekly-inbox mode only after the initial cleanup produces at least one keep, archive, protect, decide-later, or reviewed-delete decision. A user SHALL still be able to start a full rescan from Statistics.

#### Scenario: Initial scan has no decision
- **WHEN** the user views diagnosis but makes no cleanup decision
- **THEN** the system keeps the initial-cleanup entry state and does not claim weekly setup is complete

#### Scenario: Initial cleanup has a real decision
- **WHEN** the user completes initial cleanup with at least one supported decision
- **THEN** the Tasks tab uses the weekly inbox as its default state on future launches

### Requirement: Weekly inbox contains only real bounded work
The system SHALL generate weekly work from newly accessible assets, expired screenshots, unfinished tasks, and decide-later items. It SHALL show task count, estimated total duration, and completion progress, with default planned duration no greater than five minutes.

#### Scenario: Weekly work exists
- **WHEN** qualifying items exist for the current inbox period
- **THEN** the inbox shows their true sources, task count, estimated duration, and progress without duplicating an asset across active tasks

#### Scenario: No weekly work exists
- **WHEN** no qualifying items exist
- **THEN** the inbox states that the week is tidy and does not create synthetic tasks or lower safety thresholds

### Requirement: Weekly reminders are opt-in and user-controlled
The system SHALL request notification authorization only after meaningful initial cleanup and only in response to a clear reminder choice. It SHALL schedule at most one weekly local reminder and allow the user to disable it or change the weekday.

#### Scenario: User enables reminders
- **WHEN** the user opts into a weekly reminder after meaningful cleanup and grants notification permission
- **THEN** the system schedules one weekly local notification for the selected weekday

#### Scenario: User declines reminders
- **WHEN** the user declines notification permission or turns reminders off
- **THEN** the weekly inbox remains fully usable and no reminder is scheduled

#### Scenario: User changes reminder day
- **WHEN** the user selects another weekday
- **THEN** the prior pending weekly reminder is replaced with one reminder on the new weekday

### Requirement: Statistics measure organization, not only deletion
The system SHALL show aggregate counts for new items, processed items, archive, protection, deferral, reviewed deletion, estimated reclaimable space, and task completion trend. Values affected by iCloud or Recently Deleted SHALL be labeled estimates.

#### Scenario: User views statistics
- **WHEN** aggregate history exists
- **THEN** Statistics presents organization actions separately and does not use deletion quantity as the only success measure

#### Scenario: User clears history
- **WHEN** the user confirms clearing PhotoBox history
- **THEN** local decisions and aggregate history are cleared without changing photos or system albums

### Requirement: Weekly data remains local and content-free
The system SHALL retain weekly and statistical state on device and SHALL NOT include photo content, filenames, OCR text, precise locations, or media fingerprints in reminder payloads or aggregate records.

#### Scenario: Reminder is delivered
- **WHEN** a weekly notification is shown
- **THEN** its content contains only generic task wording and no private photo-derived content

