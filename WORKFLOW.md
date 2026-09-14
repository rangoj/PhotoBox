# Portable AI Coding Workflow

This execution contract supplements the repository's `AGENTS.md`. Commit it and
the other workflow definitions so every device uses the same routes and gates.

## Start Every Task

Before editing, state:

1. `Route`: Quick, Standard, or Spec.
2. `Why`: the concrete routing reason.
3. `Context`: instructions, docs, code paths, callers, and state sources read.
4. `Validation Harness`: the fastest repeatable check, prerequisites, and
   observable pass/fail signals.

Run `./Scripts/ai-workflow doctor` after installation or environment changes.
Run `./Scripts/ai-workflow validate --route <route>` on the final working tree.
Validation never installs dependencies, formats code, regenerates files,
stages changes, or restores work.

## Routes

Quick is limited to configured documentation paths. It becomes invalid when
runtime behavior, resources, configuration, scripts, dependencies, or project
structure change.

Standard covers bounded ordinary behavior in one module. It requires relevant
context, a focused harness, configured Standard commands, and a read-only
`reviewer` pass. Use OpenSpec when behavior or acceptance criteria are unclear.

Spec covers sensitive or broad work such as shared infrastructure, public
contracts, security, authentication, payment, persistence/migration,
concurrency, device/hardware behavior, dependencies, generated sources, or
project/build configuration. It requires an explicit behavior contract and
failure/recovery cases, all Standard evidence, and read-only `reviewer` plus
`test_reviewer` passes.

Spec also requires an active OpenSpec change. Use `$openspec-explore` when the
shape of the work is unclear, `$openspec-propose` to establish proposal,
requirements, design, and tasks, `$openspec-apply-change` during implementation,
and `openspec validate <change>` before archive. Supply the change name to
final validation with `--openspec-change NAME`. That argument acknowledges the
human approval decision; the validator checks non-empty artifacts and OpenSpec
schema validity, but cannot infer stakeholder approval.

OpenSpec is the authority for persistent requirements, design, and tasks.
Superpowers supplies applicable execution methods: brainstorming, TDD,
systematic debugging, code review, and verification. Do not maintain a second
Superpowers plan when OpenSpec tasks already define the implementation plan.

Routes may upgrade as risk becomes clearer. They may not downgrade below the
minimum computed from changed paths.

## Feedback Loop

1. Establish a failing or observable baseline.
2. Make the smallest relevant change.
3. Run the fastest focused harness and classify failures.
4. Correct and repeat on current code.
5. Expand validation according to risk.
6. Review the final diff and run required read-only reviewers.
7. Run the final workflow validator.
8. Report commands, outcomes, environment, unverified items, and residual risk.

`--reviewed-by NAME` acknowledges a completed review; it does not run one.
`--harness-evidence TEXT` records the focused check that actually ran.

## Integration Prerequisites

OpenSpec requires Node.js 20.19 or newer, the `openspec` CLI, an initialized
`openspec/config.yaml`, and Codex Skills under `.agents/skills/openspec-*`.
Superpowers must be installed as the official Codex plugin and expose its
`using-superpowers` bootstrap Skill. `doctor` reports missing integration as
`UNVERIFIED`; never treat absence as a successful optional check.

## Evidence

- `PASS`: ran and met its acceptance condition.
- `FAIL`: a deterministic condition failed.
- `WARN`: useful non-blocking information.
- `UNVERIFIED`: required evidence could not be obtained.
- `SKIP`: the check does not apply.

Exit codes are `0` pass, `1` deterministic failure, `2` invalid configuration
or arguments, `3` required unverified evidence, and `4` missing environment.

## Generated Files

Outputs in `.ai-workflow/generated-files.yml` must be changed through registered
sources and verified with the declared command. Do not weaken the guard to hide
stale output.

## Repository Boundary

This phase has no CI gate or Git Hook. Enforcement applies only in trusted
Codex project Hooks and explicit local validation. Keep `AGENTS.md`, this file,
`.ai-workflow/`, `.codex/`, `Scripts/ai-workflow*`, `openspec/`, and generated
OpenSpec Codex Skills Git-visible and commit them through the normal repository
workflow. Each device still installs external CLIs and plugins separately.
