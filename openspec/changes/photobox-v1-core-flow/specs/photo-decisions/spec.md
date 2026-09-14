## Purpose

Defines the local decision model for keep, delete candidate, archive, protect, and decide later, including undo, protection priority, queues, and relaunch-safe persistence.

## ADDED Requirements

### Requirement: Every asset has one current cleanup decision
The system SHALL support keep, delete candidate, archive, protect, and decide later as discoverable decisions. Archive and delete candidate states SHALL be mutually exclusive, and changing a decision SHALL replace the prior pending decision rather than stack conflicting actions.

#### Scenario: User marks an asset for deletion
- **WHEN** the user chooses delete before system submission
- **THEN** the asset becomes a reversible delete candidate and remains present in the photo library

#### Scenario: User selects an archive target after delete
- **WHEN** the user archives an asset currently marked as a delete candidate
- **THEN** the pending delete decision is removed and the archive decision becomes current

#### Scenario: User keeps an asset
- **WHEN** the user chooses keep
- **THEN** the system records the asset as processed without mutating the photo library

### Requirement: Pending decisions support undo
The system SHALL allow the most recent pending decision to be undone until its PhotoKit mutation has been successfully submitted. Undo SHALL restore the previous task and aggregate state.

#### Scenario: Undo before mutation
- **WHEN** the user invokes undo after a pending decision and before successful submission
- **THEN** the prior decision, task position, counts, and estimated space are restored

#### Scenario: Undo after successful system deletion
- **WHEN** the user attempts to undo an asset already accepted by the system deletion request
- **THEN** the system explains that recovery must occur through Recently Deleted and does not pretend to restore the asset

### Requirement: Protection overrides automatic deletion selection
The system SHALL exclude manually protected and favorited assets from default deletion selections. Removing protection SHALL not immediately create a delete candidate.

#### Scenario: User protects an asset
- **WHEN** the user marks an asset as protected
- **THEN** it is removed from pending automatic delete selections and appears in the protected queue

#### Scenario: User removes manual protection
- **WHEN** the user removes an asset from the protected queue
- **THEN** the asset becomes undecided or returns to eligible review without being preselected for deletion immediately

#### Scenario: User explicitly deletes a favorite in review
- **WHEN** the user actively selects a favorited asset for deletion in the unified review
- **THEN** the system permits the explicit choice while continuing to identify the favorite status

### Requirement: Decide-later items return without pressure
The system SHALL place deferred items in a dedicated queue, present them again in a subsequent weekly inbox, and allow repeated deferral without treating it as keep or delete.

#### Scenario: Item is deferred
- **WHEN** the user chooses decide later
- **THEN** the item leaves the current task, enters the decide-later queue, and is scheduled for a later inbox

#### Scenario: Deferred item is deferred again
- **WHEN** the user again chooses decide later during a later review
- **THEN** the system preserves the item and reschedules it without penalty or fabricated urgency

### Requirement: Decisions persist safely across relaunches
The system SHALL persist stable asset identifiers, current decisions, timestamps, task references, and aggregate counters locally. Missing or inaccessible assets SHALL be reconciled without applying a decision to another asset.

#### Scenario: App relaunches with pending decisions
- **WHEN** the application starts after termination with unsubmitted decisions
- **THEN** the exact pending decisions and task progress are restored for still-accessible asset identifiers

#### Scenario: Referenced asset no longer exists
- **WHEN** a persisted decision references an asset that is no longer accessible
- **THEN** the system invalidates only that decision, adjusts aggregates, and reports the change without substituting another asset

