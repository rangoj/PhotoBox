## 1. Decision surface

- [x] 1.1 Connect B01 to the existing task route with a single black decision surface, real thumbnail loading, undo, and VoiceOver actions.
- [x] 1.2 Implement direction-locked, once-per-drag gesture triggering for delete, keep, favorite, and archive.

## 2. Inline archive landing page

- [x] 2.1 Add inline B04/B09 album panel with loading, search, multi-select, create, and submit states.
- [x] 2.2 Use membership-only inline addition that stays on the current photo, with missing/failed target recovery and legacy result/review compatibility.

## 3. Validation

- [x] 3.1 Add focused flow coverage for multi-target album selection.
- [ ] 3.2 Run configured Debug/Release, unit/UI, reviewer, and OpenSpec validation; record simulator limitations separately.

## 4. Interaction regression closure

- [x] 4.1 Verify persisted filmstrip selection, full-batch completion, overwrite undo, and favorite operation locking.
- [x] 4.2 Verify short drags, linear reversal, first threshold crossing, and album preview touch ownership in UI.
- [ ] 4.3 Inspect real-photo screenshots at 393 pt, 375 pt and accessibility text sizes, and verify VoiceOver equivalents.
