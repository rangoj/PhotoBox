## ADDED Requirements

### Requirement: B01 gestures trigger one action at the threshold

The decision surface SHALL lock the first clearly dominant direction after the recognition zone, use the lock position as zero, show linear progress to 100 effective points, and trigger once at the first crossing before touch end.

#### Scenario: Short drag or cancellation
- **WHEN** a drag ends or is interrupted below 100 effective points
- **THEN** feedback and the album preview return to rest with no decision or membership mutation

#### Scenario: Threshold and reversal
- **WHEN** a locked drag crosses 100 effective points and then reverses
- **THEN** exactly one action runs and further movement during the same touch is ignored

### Requirement: Inline album addition preserves the current photo

The B01 archive action SHALL reveal a panel with accessible albums, search, multi-selection, creation, and one selected-count submit action. It SHALL record membership mutations without changing the photo decision or cleanup position.

#### Scenario: Multiple albums succeed
- **WHEN** two selected targets successfully receive the photo
- **THEN** the panel closes, both memberships persist, and the same photo and cleanup count remain

#### Scenario: One target fails
- **WHEN** a later target fails after an earlier target succeeded
- **THEN** completed membership remains, the failed selection remains retryable, and completion is not reported prematurely

#### Scenario: Create or submit is suspended
- **WHEN** a membership or creation operation awaits its result
- **THEN** duplicate submissions and conflicting navigation are disabled and a failure is visible in the active panel or creation sheet

### Requirement: Browsing and undo preserve the batch

The filmstrip SHALL preserve fixed order, persist the selected cursor, allow revision of pending decisions, and complete only when every eligible photo has a decision.

#### Scenario: Last photo selected first
- **WHEN** the user selects the final photo and decides it while earlier photos remain
- **THEN** the next undecided photo is shown and the batch stays incomplete

#### Scenario: Pending deletion changed and undone
- **WHEN** a pending deletion is changed to keep and then undone
- **THEN** the previous deletion is restored without double-counting the photo

### Requirement: Favorite toggling stays on the current photo

Favorite and unfavorite SHALL mutate the displayed photo once, leave the decision count unchanged, and release busy state after success or failure.

#### Scenario: Favorite operation pending
- **WHEN** a favorite change is awaiting confirmation
- **THEN** conflicting selection and decision actions are disabled and the result is applied to the originating photo
