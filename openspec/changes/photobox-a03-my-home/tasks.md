## 1. Contract

- [x] 1.1 Read A03 source documentation and existing personal/statistics/repository flows; record scope and latest Stitch retrieval limitation in proposal, design and requirements.
- [x] 1.2 Validate OpenSpec artifacts and use the user's explicit A03 implementation request as execution authorization; keep a single canonical task list. Strict validation PASS.

## 2. Read-only Data

- [ ] 2.1 Implement home totals and completed history projection; unit tests verify live-only deletion deduplication, candidate/simulation distinctions, date ordering and existing processed-count semantics.
- [ ] 2.2 Implement repository load/retry state and refresh; test empty, failure, reload after clear and no mutation during reads.

## 3. Presentation

- [ ] 3.1 Implement dark A03 header, equal metrics, primary rows and retained recovery tools; UI tests verify native tabs and legacy entry identifiers.
- [ ] 3.2 Add read-only records, help, feedback draft/share and bundle-derived about content; verify child tabs hidden, back navigation and draft behavior.
- [ ] 3.3 Verify 375/393-point and accessibility-size screenshots and hit regions using deterministic fixtures.

## 4. Final Verification

- [ ] 4.1 Run configured Debug/Release builds, unit and UI suites; record reproducible PASS/FAIL/UNVERIFIED evidence and keep preexisting A02 failures distinct.
- [x] 4.2 Obtain read-only reviewer and test_reviewer checks, fix actionable findings and record their evidence. Both scoped re-reviews report no remaining blocking findings; see `Docs/PhotoBox_A03_Verification.md`.
- [ ] 4.3 Run strict OpenSpec and final `ai-workflow validate --route spec --openspec-change photobox-a03-my-home` with actual harness/reviewer evidence.
