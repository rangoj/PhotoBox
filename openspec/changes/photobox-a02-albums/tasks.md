## 1. Contract and Baseline

- [x] 1.1 Read the actual Stitch A02 screen and record the user's removal of search and user icons in proposal, spec, and design; verify artifact consistency.
- [x] 1.2 User approved implementation with "确定，执行开发". Configured unit baseline PASS, exit 0, `/tmp/photobox-a02-baseline.log`.

## 2. Collection Data

- [x] 2.1 Add collection directory/member reading and a testable album projection; test favorites separation, localized ordering, duplicate titles, recent-ID fallback, empty albums, authorized media counts, and cloud placeholders. Unit PASS: `/tmp/photobox-a02-unit-final.log`.
- [x] 2.2 Implement observable home and collection load states; test cancellation, stale response suppression, limited-access changes, missing albums, failure retry, rename and membership-only refresh. Includes collection-only events preserving unscanned cleanup records.

## 3. New Album

- [x] 3.1 Implement create-only state using the current mutator; test trim validation, cancellation, single submission, failure/uncertainty recovery, successful creation followed by read failure, and zero photo decisions or archive calls.
- [x] 3.2 Preserve the existing backend selection and clearly distinguish simulated creation; test mode changes and verify the legacy create-and-archive tests still pass. Full configured unit suite PASS, exit 0, including 24 A02 tests.

## 4. Presentation and Navigation

- [ ] 4.1 Implement A02's Chinese title plus add command, quick-access covers, two-column album grid and queue rows; verify absence of search/user icons and unsupported state claims in deterministic UI tests.
- [ ] 4.2 Add the native creation dialog and read-only collection grid route; verify empty, loading and failure states, hidden child tabs, restored home position, queue entry reachability and no browsing mutations.
- [ ] 4.3 Add local-image fixtures and screenshot assertions for 375/393 pt, long names, large text, VoiceOver semantics and 44 pt commands; inspect images for actual rendered covers, clipping and safe-area overlap.

## 5. Integration Verification

- [ ] 5.1 Run configured Debug and Release builds plus unit and UI suites; record exact commands, environment, logs and actual PASS/FAIL/UNVERIFIED outcomes.
- [x] 5.2 Obtain read-only reviewer and test_reviewer findings for the final implementation and resolve actionable issues; record review identities and follow-up checks. Final scoped reviews cover activation-only scroll capture; remaining nonblocking test gaps are recorded in `Docs/PhotoBox_A02_Verification.md`.
- [ ] 5.3 Run OpenSpec validation and `./Scripts/ai-workflow validate --route spec --openspec-change photobox-a02-albums` with actual harness and reviewer evidence; report outstanding device-only checks without claiming they passed.
