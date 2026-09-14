## Purpose

Defines diagnosis summaries, ranked cleanup work, conservative photo recommendations, exclusive task ownership, and observable task lifecycle and result behavior.

## ADDED Requirements

### Requirement: Diagnosis distinguishes storage concepts
The system SHALL summarize each available cleanup category with item or group count, estimated handling time, risk, and estimated reclaimable space. It SHALL distinguish current photo storage from estimated reclaimable space and SHALL explain that Recently Deleted delays permanent reclamation.

#### Scenario: Diagnosis contains candidates
- **WHEN** a usable scan produces cleanup candidates
- **THEN** the diagnosis shows truthful category counts and an estimated, not guaranteed, reclaimable-space value

#### Scenario: Diagnosis contains no candidates
- **WHEN** scanning finds no qualifying cleanup candidates
- **THEN** the system shows a healthy-library state and a suggested next check instead of generating artificial tasks

### Requirement: Tasks are ranked by trust and value
The system SHALL rank high-confidence low-risk tasks before high-space, new-content, and deferred work. Each task SHALL identify its subject, verifiable reason, estimated duration, estimated space, and risk level.

#### Scenario: High-risk task has greater space value
- **WHEN** a high-risk task could reclaim more space than a high-confidence low-risk task
- **THEN** the system does not promote the high-risk task ahead solely because of space value

#### Scenario: User skips a task
- **WHEN** the user skips a task
- **THEN** the system records no photo decision, lowers that task's short-term priority, and allows it to return later

### Requirement: One active task owns each asset
The system SHALL prevent the same asset from appearing in more than one in-progress task while allowing uncommitted tasks to pause and resume.

#### Scenario: Candidate belongs to multiple categories
- **WHEN** one asset qualifies for more than one task type
- **THEN** the highest-priority active task owns it and other active tasks exclude it until ownership is released

#### Scenario: Task resumes after relaunch
- **WHEN** the app relaunches with a paused or in-progress task
- **THEN** the task restores its remaining assets and recorded decisions without duplicating completed work

### Requirement: Similar and burst groups remain user-controlled
The system SHALL present comparable assets together, allow inspection and selection changes, and MAY preselect keep and delete candidates only when the recommendation is conservative. A recommended keep item SHALL have at least one verifiable reason.

#### Scenario: Recommendation has sufficient confidence
- **WHEN** a group has a confidently preferred item based on supported local signals
- **THEN** the system labels the item as recommended, displays at least one true reason, and allows the user to override every preselection

#### Scenario: Recommendation confidence is low
- **WHEN** supported signals do not yield a confident preferred item
- **THEN** the system asks the user to choose what to keep and does not display a best-photo label

#### Scenario: Protected evidence is present
- **WHEN** an item is manually protected, favorited, or reliably recognized as edited
- **THEN** it is not preselected for deletion even if another item has stronger visual-quality signals

#### Scenario: Group is completed
- **WHEN** the user completes decisions for one group
- **THEN** the system advances to the next group and updates cumulative deletion candidates and estimated space

### Requirement: Task completion produces a truthful result
The system SHALL summarize delete candidates submitted, successful archives, protections, deferred items, processing time, and estimated reclaimable space, and SHALL provide a next task or return path without a paywall.

#### Scenario: Cleanup completes
- **WHEN** a cleanup task reaches a terminal result
- **THEN** the result reports each action count separately and does not describe Recently Deleted content as permanently freed space

#### Scenario: Task has no delete operation
- **WHEN** a task completes using only keep, archive, protect, or decide-later decisions
- **THEN** the system still treats it as meaningful cleanup and reports zero deletion candidates truthfully

