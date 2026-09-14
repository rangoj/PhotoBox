# PhotoBox AI Collaboration Guide

The workflow manager created this repository instruction entry because the
project did not already provide `AGENTS.md`. Keep it in Git with the other
workflow definitions so every device receives the same collaboration contract.

## Required Context

- Read this file and `WORKFLOW.md` before changing the project.
- Read the closest module documentation and instruction files for every changed
  area, then inspect direct callers and state sources.
- Follow existing project architecture and dependencies; keep changes focused.

## Task Contract

Before editing, state `Route`, `Why`, `Context`, and `Validation Harness` as
defined in `WORKFLOW.md`. Routes may upgrade but may not downgrade.

## Specification And Method

- Quick work does not require an OpenSpec change.
- Standard work uses OpenSpec when behavior or acceptance criteria are unclear.
- Spec work requires an OpenSpec change with proposal, requirements, design,
  and tasks approved before implementation.
- OpenSpec owns persistent requirements, design, and task artifacts.
- Superpowers supplies the applicable working method, such as brainstorming,
  test-driven development, systematic debugging, review, and verification.
- Do not create a second Superpowers plan when OpenSpec tasks are already the
  canonical implementation plan.

## Completion

Run the final harness and `./Scripts/ai-workflow validate --route <route>` with
the selected route and its required evidence. Report reproducible PASS, FAIL,
WARN, UNVERIFIED, and SKIP evidence. Never claim that a Hook, reviewer
acknowledgement, or written expectation substituted for a check.

## Project Context

- PhotoBox is a SwiftUI iOS 17 application built from `PhotoBox.xcodeproj` with
  app, Swift Testing unit-test, and XCTest UI-test targets.
- Production sources live under `PhotoBox/`; focused unit and UI coverage lives
  under `PhotoBoxTests/` and `PhotoBoxUITests/`.
- Photo-library authorization, Photos framework access, scan cancellation, and
  local-versus-iCloud classification are sensitive behavior and require the
  Spec route.
- Use only the non-interactive Xcode commands configured in
  `.ai-workflow/config.yml`; keep derived data outside the repository.
