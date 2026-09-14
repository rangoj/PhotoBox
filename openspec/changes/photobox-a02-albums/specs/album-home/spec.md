## Purpose

Provide a photo-first album home that reflects authorized system collections, keeps favorites and cleanup queues distinct, and lets users create empty albums and inspect their contents without making cleanup decisions.

## ADDED Requirements

### Requirement: A02 dark album home

The album home SHALL follow Stitch screen `a302d7e03af049e6b38314b11f2083f3` with a single Chinese title and an add command. It SHALL omit search, the user icon, and the redundant English header. It SHALL present compact horizontal quick-access covers, a two-column square-cover album grid, and the existing deferred and protected queue entries. Titles and counts SHALL be below covers, without surrounding cards.

#### Scenario: User selects Albums
- **WHEN** the user selects the 相册 tab
- **THEN** the home shows 相册 and an accessible 新建相册 command, with the native three-tab bar selecting 相册
- **THEN** no search or user icon is displayed

### Requirement: Authorized collection data

The home SHALL show accessible regular user albums and a favorites collection, using stable collection identities, actual names, accessible member counts, and real covers where available. Album membership SHALL include authorized photos, Live Photos, panoramas, and videos; videos SHALL have truthful media labels. Cloud-only members SHALL count without forcing downloads. Empty albums SHALL remain visible with a fixed-size placeholder. Favorites SHALL remain distinct from app-protected decisions.

#### Scenario: Album contains local and cloud-only members
- **WHEN** an album contains two accessible local members and one cloud-only member
- **THEN** its count is three and unavailable cover data uses a placeholder without triggering a download

#### Scenario: Album names collide
- **WHEN** two accessible albums have the same title
- **THEN** they remain separate entries with their own counts and destinations

### Requirement: Deterministic quick access

Quick access SHALL place favorites first, followed by at most three accessible, distinct recently used albums. If fewer than three recent albums exist, remaining positions SHALL use the regular album ordering. Regular albums SHALL sort by localized title with a stable identity tie-breaker. The app SHALL not claim collections are pinned unless a pin feature exists.

#### Scenario: A recently used album disappears
- **WHEN** the album is no longer accessible
- **THEN** refresh removes its shortcut and fills the position from available albums without changing stored photo decisions

### Requirement: Create an empty album

The add command SHALL open a native name-entry dialog with create and cancel actions. Whitespace-only names SHALL be rejected. Cancel SHALL perform no mutation. Creation SHALL submit at most once while in flight, honor the selected mutation backend, and not archive, favorite, protect, delete, or decide any photo. A successful creation SHALL show the new empty album. Failure SHALL retain the name and provide an appropriate retry or refresh action; an uncertain result SHALL not be automatically resubmitted. Simulated creation SHALL never be reported as a system-library change.

#### Scenario: User creates an album
- **WHEN** the user submits a nonempty trimmed name and creation succeeds
- **THEN** the dialog closes and the new album is visible with zero members
- **THEN** cleanup progress and existing photo memberships are unchanged

#### Scenario: User submits repeatedly during creation
- **WHEN** creation is pending and the create control is activated again
- **THEN** only one creation request is sent

### Requirement: Browse contents within the source tab

Opening an ordinary album or favorites SHALL show that collection's accessible members in a basic read-only three-column grid. The child page SHALL hide tabs and show one navigation bar. Returning SHALL preserve the Albums tab and home scroll position. Browsing SHALL produce no cleanup decisions or mutations. Deferred and protected entries SHALL retain their existing distinct routes and actions.

#### Scenario: User returns from an album
- **WHEN** the user opens an album, inspects its contents, and returns
- **THEN** the home restores its prior position and photo decisions remain unchanged

### Requirement: Recovery and accessibility

The home SHALL distinguish loading, empty albums, empty favorites, read failure, unavailable collection, and limited access. Permission changes SHALL invalidate stale collection contents before displaying data from the new scope. Failures SHALL offer retry without falsely reporting zero albums. Returning from the background and explicit refresh SHALL reflect album additions, removals, renames, favorites, and membership changes even when no asset was added or deleted. Text SHALL wrap at 375-point width and accessibility sizes; commands SHALL have meaningful VoiceOver labels and at least 44-point touch targets. The UI SHALL not claim Face ID protection, Pro services, or cloud sync status that the app does not implement.

#### Scenario: Read fails then recovers
- **WHEN** collection loading fails and a subsequent retry succeeds
- **THEN** the error is replaced by the actual authorized collection list

#### Scenario: Access is reduced
- **WHEN** access changes from full to limited
- **THEN** stale contents are hidden until revalidated and refreshed counts include only accessible members
