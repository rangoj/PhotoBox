## Design

The authoritative interaction contract is `Docs/PhotoBox_Stitch_Batch_2.md`. B01 stays on the existing task route and displays a black, full-photo viewport with one filmstrip. Main-photo loading is independent of the filmstrip.

`DecisionDragState` locks a clearly dominant axis after the recognition zone. The lock position becomes effective distance zero. Progress is linear, clamped at 100 effective points, and the first crossing triggers once before touch end. The recognizer remains attached while an album preview appears. Cancellation resets only transient presentation. Album list hit testing begins after the initiating touch ends.

`AppModel` prepares `AlbumSelectionFlow` for the displayed photo. Every inline target uses a journaled membership mutation without a `PhotoDecision`; successful targets are removed from the pending selection and failed targets can be retried. Completion closes the panel and leaves the same photo and cleanup count. Legacy routed archive operations keep their decision and result semantics. Creation and submission are single-flight; navigation is disabled until their result is known.

Filmstrip selection persists the displayed cursor before changing presentation. Pending decisions can be revisited without increasing the unique processed count. Choosing the last photo cannot complete a batch with earlier undecided members; next-photo selection wraps in fixed order. Favorite results belong to the originating flow and asset, with conflicting interactions blocked during the operation. Undo restores the prior decision and count.

## Contract reconciliation

The initial change draft reused archive-as-decision for inline addition. The B09 and batch requirements explicitly say addition stays on the current photo and does not imply keep. The implementation and regression tests use that UI contract, preserving the old behavior only for legacy routed archive callers.
