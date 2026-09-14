## 1. Contract and Baseline

- [x] 1.1 Capture the user-approved A01 plan as proposal, requirements and design; verify CLI artifact readiness.
- [x] 1.2 Run the configured unit suite before implementation and record baseline outcome. PASS: configured unit command, /tmp/photobox-a01-baseline.log, exit 0. Sandboxed first attempt could not access Simulator; identical command passed with Simulator access.

## 2. Collection Domain

- [ ] 2.1 Implement home projection with tests for month sorting, dates, media scope, submitted decisions and undo.
- [ ] 2.2 Implement balanced immutable daily batches and additive task type with tests for 56/120 splits, cross-entry resume, random selection, cloud exclusion, ownership and inventory changes.

## 3. Integration and Presentation

- [ ] 3.1 Integrate AppModel home state, persistence and source-correct routing; verify repository-backed launch, progress, failure and completion tests.
- [ ] 3.2 Implement dark A01, duplicate list and three-tab shell with My recovery rows; verify real thumbnails, navigation, first-screen month visibility and conditional state actions.
- [ ] 3.3 Add deterministic local-photo UI fixtures and migrate navigation coverage; verify four entrances, completion, limited/empty/error states, 375/393-point layouts and accessibility.

## 4. Final Validation

- [ ] 4.1 Run configured Debug/Release builds and unit/UI suites; record exact outcomes and screenshot evidence.
- [ ] 4.2 Complete read-only reviewer and test_reviewer passes and resolve actionable findings; record identities and outcomes.
- [ ] 4.3 Validate OpenSpec and run the final Spec workflow validator with actual harness and reviewer evidence; report remaining unverified device checks.
