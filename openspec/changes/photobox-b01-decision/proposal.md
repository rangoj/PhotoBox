## Why

B01 currently renders the single-photo decision surface, but downward archive actions still leave the page for a legacy album route. The approved B01–B10 design requires a gesture-first landing page with an inline album panel and resumable mutation feedback.

## What Changes

- Keep the single-photo B01 surface connected to the existing task route and real decision persistence.
- Lock gesture direction, trigger each action once at 100 pt, and keep feedback at the top of the page.
- Open a B04/B09-style inline album panel for multi-select, search, creation, and archive submission.
- Follow B09 membership-only inline addition while preserving legacy routed archive, result, delete-review, favorite, undo, accessibility, and recovery behavior.

## Impact

SwiftUI decision and album flows, AppModel route coordination, mutation persistence, and focused unit/UI coverage. No new dependencies or changes to PhotoKit download policy.
