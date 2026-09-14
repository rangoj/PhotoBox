## Purpose

Defines trustworthy full and incremental photo-library diagnosis, including permission boundaries, local availability, progress, cancellation, recovery, and conservative candidate discovery.

## ADDED Requirements

### Requirement: Authorization gates real scanning
The system SHALL explain the benefit, local-processing policy, and permission use before requesting photo-library access. It SHALL scan only assets visible under full or limited access and SHALL never present fabricated scan results.

#### Scenario: User grants full access
- **WHEN** the user grants full photo-library access
- **THEN** the system starts a real scan of the accessible library and reports the granted scope

#### Scenario: User grants limited access
- **WHEN** the user grants limited access
- **THEN** the system scans only the selected assets, persistently labels the result as limited, and offers a system-supported way to manage accessible photos

#### Scenario: Access is denied or restricted
- **WHEN** access is denied or restricted
- **THEN** the system does not scan and presents a recoverable state without repeatedly triggering the system permission prompt

#### Scenario: Permission changes during a scan
- **WHEN** photo-library access becomes insufficient during an active scan
- **THEN** the scan stops, preserves only safe completed progress, and reports that authorization changed

### Requirement: Scan exposes truthful progress and cancellation
The system SHALL report the current stage, discovered asset count, processed asset count, partial category counts, and whether scanning is active. The user SHALL be able to cancel an active scan without blocking the main interface.

#### Scenario: Partial results become available
- **WHEN** enough assets have been processed to produce a usable category result
- **THEN** the system publishes the partial result before the full scan finishes and clearly keeps the scan marked in progress

#### Scenario: User cancels scanning
- **WHEN** the user cancels an active scan
- **THEN** work stops promptly, completed safe progress remains recoverable, and no cancelled analysis result is committed later

#### Scenario: Application is relaunched after interruption
- **WHEN** an unfinished scan is found after app relaunch
- **THEN** the system offers to resume from safe progress or restart and does not claim the scan completed

### Requirement: Scan classifies accessible assets conservatively
The system SHALL distinguish locally analyzable, iCloud-only, and unavailable assets without automatically downloading iCloud originals. It SHALL identify expired screenshots, large-video diagnostics, duplicates, similar groups, and bursts only from sufficient available evidence.

#### Scenario: Original is available only in iCloud
- **WHEN** an asset cannot be analyzed without a network download
- **THEN** the system records it as iCloud-only or analysis-pending and continues scanning other assets without generating an unsupported recommendation

#### Scenario: Large video is found
- **WHEN** an accessible video meets the P0 large-video diagnostic threshold
- **THEN** the system includes it in space diagnosis but does not create a compression or automatic deletion action

#### Scenario: Similarity evidence is insufficient
- **WHEN** local signals are insufficient to establish a duplicate, similar, or burst relationship
- **THEN** the system excludes the asset from that candidate group instead of lowering the threshold to manufacture work

### Requirement: Scan supports incremental library changes
The system SHALL detect accessible-library changes after an initial scan, merge additions and removals by stable asset identity, and avoid requiring a full rescan for every change.

#### Scenario: New assets are added
- **WHEN** the library contains assets created after the last completed scan
- **THEN** the system analyzes the new accessible assets and merges resulting candidates without discarding completed decisions

#### Scenario: Asset disappears before result use
- **WHEN** an asset referenced by a scan result is no longer accessible
- **THEN** the system removes or invalidates that reference without failing unrelated tasks

### Requirement: Scan data remains private and bounded
The system SHALL perform P0 media analysis on device and SHALL NOT persist image content, thumbnails, filenames, precise locations, feature vectors, OCR text, face data, or reversible media fingerprints. It SHALL use bounded thumbnail and paging behavior rather than keeping full-resolution media resident in bulk.

#### Scenario: Scan progress is persisted
- **WHEN** the system saves resumable scan state
- **THEN** it stores only stable asset identifiers, timestamps, category state, and aggregate counts required for recovery

#### Scenario: Core workflow is offline
- **WHEN** the device has no network connection and accessible assets are local
- **THEN** authorization-aware scanning and candidate generation remain usable without a remote service

