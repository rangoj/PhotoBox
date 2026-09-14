# A02 Verification Evidence

Change: `photobox-a02-albums` (Spec), approved by the user on 2026-09-14.
Reference: Stitch screen `a302d7e03af049e6b38314b11f2083f3`, project `11208455012423558853`.
Header: Chinese title and add command; no search or user command.

## Harness

All Xcode commands are the commands in `.ai-workflow/config.yml`, with derived data in `/tmp`.
Tests run on iPhone 17, iOS Simulator 26.3.1. No real user photo library is modified by fixtures.

| Check | Result | Evidence |
| --- | --- | --- |
| Unit baseline | PASS | `/tmp/photobox-a02-baseline.log`, exit 0 |
| Initial behavior red | FAIL, expected | `/tmp/photobox-a02-red.log`: no-op models fail collection/create/content assertions; old scan tests also timed out under load |
| Final unit implementation | PASS | `/tmp/photobox-a02-unit-final.log`, exit 0; 24 A02 tests and 341 total successful test invocations |
| Workflow Debug build | PASS | `.ai-workflow/logs/project-1.log` |
| Workflow unit suite | PASS | `.ai-workflow/logs/project-2.log`; 343 passed invocations, including two scroll-position regressions |
| Workflow Release build | PASS | `.ai-workflow/logs/project-3.log` |
| Final UI suite and screenshots | Pending | `.ai-workflow/logs/project-4.log` |
| Strict OpenSpec schema | PASS | `openspec validate photobox-a02-albums --strict` |
| Final workflow | Pending | `/tmp/photobox-a02-validation-final.log` |

The initial UI run (`/tmp/photobox-a02-ui.log`) was stopped after identifying failures in the superseded implementation. Its partial results are diagnostic evidence only. Fixed causes include the native toolbar's 36-point add element, toolbar wrapper queries, inherited retry identifiers, the queue row's unfilled center hit area, and A01 assertions reading a displayed position as an accessibility value instead of its label. No assertions or tests were removed.

The workflow secret scan initially matched the long Swift test method name beginning with `sk`. The method was renamed to `archiveCursorRemainsAlignedAfterSkippedMember`; its body and the scanner rules are unchanged.

## Reviews

- `reviewer`: `/root/a02_review`, read-only review and scoped re-review. Found P1: collection-only notifications could reconcile persisted decisions against an unready empty inventory. The handler now returns before asset reconciliation for zero asset deltas. `collectionOnlyChangesPreserveUnscannedWork` verifies saved decisions, task members, owned IDs and cursor survive two serial notifications. Re-review: addressed, no new concrete regressions.
- `test_reviewer`: `/root/a02_test_review`, read-only review and scoped re-review. Added coverage for already-open content during scope reduction and actual screenshot photo pixels. Re-review: both findings addressed in test code. The timed scope fixture has a bounded wait and may expose simulator overload as a test failure.
- Final scroll-restoration review: `/root/a02_review` found that capturing on press could retain a canceled press's position. The final `PrimitiveButtonStyle` captures only on activation before triggering the existing NavigationLink; re-review found the issue resolved and no new concrete regressions. `/root/a02_test_review` found no new blocking test issues. Two UIKit geometry/lifecycle unit tests passed; the unchanged UI return-position assertion requires a difference of at most 6 pt.
- Remaining focused test gaps: geometry changes after `viewWillAppear`, content-shrink clamping, and active-drag cancellation are not individually isolated in unit tests. Actual navigation timing is covered by the UI regression; physical VoiceOver activation remains unverified.

## Device-Only Limits

UNVERIFIED: real-device PhotoKit album enumeration under limited access, actual system-album creation, and cloud-only media with an uncached thumbnail. Code continues to use the existing request options with `isNetworkAccessAllowed = false`; simulated collection creation is explicitly labeled and does not mutate system photos.

UNVERIFIED: manual VoiceOver navigation on a physical device. Simulator accessibility labels, dynamic text, hit regions and clipping are included in the UI harness.

The separately discussed cold-start full scan remains an existing behavior. Completed scan checkpoints do not restore a persistent descriptor index; an incremental startup scan requires a separate persistence and scanning change.
