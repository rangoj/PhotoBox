## Context

See proposal.md. `MyWorkspaceView` already owns recovery commands and navigation to settings/statistics. `StatisticsProjection` defines the existing processed-photo counting semantics. Repository summaries have stable IDs but do not retain per-photo identities; deletion transactions retain outcome and optional backend identity. No completed-history page exists.

## Goals / Non-Goals

Goals: implement the documented A03 composition, truthful totals and read-only historical outcomes while retaining existing recovery commands.

Non-goals: full A06 redesign, new analytics persistence, login, support backend, automatic feedback submission, PhotoKit mutation changes, incremental scan persistence, and B01 changes.

## Decisions

1. Add a small observable home model injected with the existing repository. Reuse `StatisticsProjection.processedItemCount` for the existing processed-count semantics rather than introducing a second definition. Count deleted photos by distinct IDs in succeeded live delete transactions only. Simulated or backend-unknown records remain distinguishable in history and never increase the real deletion total.
2. Read tasks, decisions, summaries and transactions in one synchronous repository-read phase, then publish together. A failed read hides totals and offers retry, never converting failure to zero. Load on entry, foreground and explicit refresh. Clear-history returning to home reloads from the same repository.
3. Read-only history presents completed summaries and completed delete transactions as distinct records, sorted by date with stable ID tie breaks and calendar day groups. It never attempts a speculative join between summaries and transactions. Summary deletion candidates use the label 待删除; live transaction success uses 已删除; simulated results use 模拟删除; unknown backend results use 删除记录（模式未知）. No transaction retries or photo restoration commands exist on this page.
4. Use an unframed dark header, two equal metric columns, plain native list rows and standard chevrons. Preserve existing automation identifiers and recovery navigation below the primary A03 section. Existing statistics remains a secondary tool. Child pages hide tabs and return to 我的. Use scalable fixed-point fonts, wrapping labels and 44-point commands.
5. Help/about use native content pages. Feedback uses a local text draft and a system share action; it has no destination address until selected by the user. Canceling the system sheet retains the draft. Version comes from the app bundle. No additional SDK or service is introduced.

## Risks / Trade-offs

- Old statistics summarize current surviving decisions rather than maintaining an immutable activity ledger. Reuse that established meaning and do not claim totals survive clearing local history.
- Backend identity is missing in older transactions. Exclude those from proven live deletions and label them explicitly in history.
- Latest Stitch image could not be retrieved. Match the repository A03 definition and current dark theme, and record latest-reference comparison as unverified.
- Existing broad UI suite is slow and A02 return-position regression remains open. Keep its evidence separate and do not describe the combined suite as passing until it does.

## Migration Plan

No storage migration. Add read-only projection and screens, then compose through AppModel and the existing 我的 NavigationStack. Reverting these screens leaves repository data and created albums intact. Validate projection/error/reload behavior, existing recovery navigation, 375/393-point layout, accessibility sizes, Debug/Release builds and the configured full suites.
