## Purpose

Provide a compact personal workspace showing truthful local cleanup totals and access to completed records, preferences, recovery actions and user-controlled support content.

## ADDED Requirements

### Requirement: A03 personal home

The home SHALL show 我的, two equal-weight numbers labeled 累计整理 and 累计删除, primary 整理记录 and 设置 rows, and lower-priority 帮助, 反馈 and 关于 destinations. It SHALL use the current dark theme without avatar, login or membership surfaces. It SHALL retain the native three-tab navigation and existing cleanup recovery and statistics commands.

#### Scenario: Open the personal tab
- **WHEN** the user opens 我的
- **THEN** the two totals and primary rows are visible, the 我的 tab is selected, and the existing unfinished-work and pending-deletion commands remain reachable

### Requirement: Truthful totals and load recovery

The processed total SHALL retain the existing statistics counting semantics. The deleted total SHALL count distinct photos only after successful confirmed live deletion. Pending, failed, simulated and backend-unknown deletion outcomes SHALL not count as real deletion. Empty history SHALL show zero; failed reading SHALL show a retryable error instead of zero. Returning to the home or foreground SHALL refresh the values without modifying any stored record.

#### Scenario: Mixed deletion outcomes
- **WHEN** records contain one successful live deletion, one candidate, one failed deletion, one simulated deletion and one backend-unknown deletion
- **THEN** 累计删除 is one

#### Scenario: Read fails
- **WHEN** local record loading fails
- **THEN** totals are unavailable and retry reloads the actual records

### Requirement: Read-only cleanup records

The records destination SHALL group completed summaries and completed delete transactions by device-calendar date, newest first. It SHALL keep candidate, actual deletion, simulated deletion and unknown backend labels distinct. Reading history SHALL never retry mutations or offer unsupported photo restoration. Secondary pages SHALL hide tabs and return to the original personal home.

#### Scenario: Summary has candidates only
- **WHEN** a completed summary contains deletion candidates without a confirmed live deletion outcome
- **THEN** it labels those photos 待删除 and never 已删除

### Requirement: Local support and accessible presentation

Help and about SHALL present native readable content and the installed app version. Feedback SHALL keep a local draft and open the system share sheet only on explicit user action, without claiming delivery. Blank drafts SHALL not be shareable. Commands SHALL remain reachable at 375-point width and accessibility text sizes with meaningful labels and at least 44-point targets.

#### Scenario: Cancel feedback sharing
- **WHEN** the user dismisses the share sheet
- **THEN** the draft remains and no sent-success state is displayed
