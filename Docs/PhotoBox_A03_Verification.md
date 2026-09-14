# A03 Verification Evidence

Change: `photobox-a03-my-home`, Spec. User requested implementation on 2026-09-14.

## Reference and Scope

Source: `Docs/PhotoBox_Stitch_Batch_1.md`, A03, with the current dark theme. Stitch project `11208455012423558853` could not be read through the connector (transport failure); the browser fallback did not yield screen contents. Matching the latest A03 screen is UNVERIFIED.

Implemented scope: personal home, processed/live-deletion totals, read-only completed records, settings and retained recovery routes, help/about, local feedback draft and system sharing. B01 visual redesign and cold-start incremental indexing are not part of this change.

## Harness

Only non-interactive Xcode commands in `.ai-workflow/config.yml`; simulator iPhone 17, iOS 26.3.1; derived data in `/tmp`.

| Check | Result | Evidence |
| --- | --- | --- |
| Initial A03 unit run | PASS | `/tmp/photobox-a03-unit.log`, exit 0, 349 passed invocations |
| Added stale-data/share/retry regressions | Pending | Final configured run below |
| Final Debug/Release builds and full unit/UI suites | Pending | `.ai-workflow/logs/project-{1,2,3,4}.log` |
| Strict OpenSpec | PASS | `openspec validate photobox-a03-my-home --strict` |
| Final workflow | Pending | `/tmp/photobox-a03-validation.log` |
| 375/393-point and large-text screenshots | Pending | `MyHomeUITests` attachments |

The initial unit run exposed a Swift concurrency warning in mutable test closure state. The test now uses a MainActor-isolated reference. No assertions were removed.

## Reviews

- `reviewer`: `/root/a02_review`, A03 full read-only review plus scoped re-review of the injectable snapshot reader. No concrete P1/P2 issues remained. Production uses the existing repository; the DEBUG failure fixture reads the same seeded storage.
- `test_reviewer`: `/root/a02_test_review`. P2 findings: a later read failure did not have coverage for clearing stale totals, and sharing cancellation/whitespace drafts were not exercised. Tests now cover these paths, plus homepage and history retry buttons. Re-review: findings addressed in code, execution pending.
- WARN: failure fixtures count reads and rely on current view lifecycle calls. Added lifecycle reloads must preserve the intended failure trigger without weakening assertions.

## A02 Follow-up

The full UI run before A03 continued to fail A02's queue-return assertion by 49 pt. Runtime evidence in `/tmp/PhotoBoxAIWorkflowUITests/Logs/Test/Test-PhotoBox-2026.09.14_17-31-07-+0800.xcresult` showed the bottom inset changing from 83 to 34 during pop, clamping offset 447 to 398 before `viewDidAppear`; the tab inset returns later. Restoration now stays active until the saved inset returns. The new `tabBarInsetSettlesAfterAppearance` unit regression passed; actual UI re-verification is pending. Temporary diagnostics were removed.

## Limits

UNVERIFIED: current Stitch pixel matching, physical-device VoiceOver and actual delivery through a user-selected share destination. The app does not claim a feedback message was sent. Local fixtures do not modify user photos.
