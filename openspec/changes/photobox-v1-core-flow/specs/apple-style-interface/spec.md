## Purpose

Defines the iPhone information architecture and restrained Apple first-party interaction style for all P0 screens, including adaptive layout, accessibility, and truthful state presentation.

## ADDED Requirements

### Requirement: Application uses the complete P0 information architecture
The system SHALL provide four top-level tabs named Tasks, Albums, Statistics, and Settings in simplified Chinese. The P0 flow SHALL make permission, scan, diagnosis, task list, similar comparison, single decision, album selection, delete review, result, weekly inbox, decide later, protected photos, album management, statistics, and settings reachable in context.

#### Scenario: Authorized user opens the app
- **WHEN** the app has a valid persisted workflow state
- **THEN** it opens the corresponding Tasks experience and keeps Albums, Statistics, and Settings available through the tab bar

#### Scenario: User follows initial cleanup
- **WHEN** the user starts from photo permission and completes the main cleanup flow
- **THEN** navigation follows permission, scan, diagnosis, task, decision, review, and result without requiring hidden gestures

### Requirement: Visual style follows native Apple conventions
The interface SHALL use native navigation bars, large titles where appropriate, system grouped backgrounds, system blue for primary actions, semantic system colors, SF Symbols, restrained separators, and corner radii no greater than eight points for framed controls. It SHALL avoid decorative gradients, oversized marketing heroes, nested cards, and custom controls that duplicate standard platform behavior.

#### Scenario: User views a work screen
- **WHEN** a task, album, statistics, or settings screen is displayed
- **THEN** hierarchy is conveyed through native typography, spacing, grouping, and semantic controls rather than ornamental containers

#### Scenario: Destructive action is available
- **WHEN** deletion can be selected or confirmed
- **THEN** the action uses the platform destructive semantic style and is visually distinct from keep, archive, and protect

### Requirement: Media decisions remain inspectable and discoverable
The interface SHALL provide visible labeled controls for all five photo decisions and SHALL identify video, Live Photo, panorama, favorite, edited, protected, and recommendation states when available. Gestures MAY accelerate actions but SHALL NOT be the only way to complete them.

#### Scenario: User does not know swipe gestures
- **WHEN** the user reaches a single-photo decision screen
- **THEN** delete, keep, archive, protect, and decide-later actions remain visible and operable

#### Scenario: User inspects a recommendation
- **WHEN** a recommended similar-group item is shown
- **THEN** its supported reason and current selection state are readable without relying on color alone

### Requirement: Core flow supports system accessibility settings
All critical actions and dynamic states SHALL expose meaningful VoiceOver labels, hints, values, and traits. Layout SHALL support Dynamic Type without clipping or action overlap, respect Reduce Motion, maintain usable touch targets, and avoid color-only status communication.

#### Scenario: VoiceOver is active
- **WHEN** a user navigates a task or decision screen with VoiceOver
- **THEN** reading order is coherent and every critical action announces its purpose and current state

#### Scenario: Accessibility text size is large
- **WHEN** the user selects an accessibility Dynamic Type size
- **THEN** content reflows and scrolls as needed while photo controls remain reachable and text is not truncated

#### Scenario: Reduce Motion is enabled
- **WHEN** a task advances or a decision changes
- **THEN** the interface uses reduced or no nonessential animation without removing feedback or functionality

### Requirement: Interface states are truthful and recoverable
Loading, empty, limited-access, cancelled, failed, partial-success, and stale-content states SHALL be explicitly represented and SHALL provide a relevant retry, settings, resume, or return action where recovery is possible.

#### Scenario: Content fails to load
- **WHEN** a screen cannot load its required accessible asset or state
- **THEN** it presents the specific failure scope and a valid recovery or exit action instead of an indefinite progress indicator

#### Scenario: Mutation partially succeeds
- **WHEN** a cleanup result contains both successes and failures
- **THEN** the result distinguishes them and offers retry only for unresolved items

### Requirement: P0 remains free of unconfirmed commercial gates
The interface SHALL NOT show a StoreKit paywall or block permission, scanning, decisions, delete review, result viewing, or recovery guidance in this change.

#### Scenario: User completes the first cleanup
- **WHEN** the result page is shown
- **THEN** all result details, Recently Deleted guidance, and navigation remain available without a purchase prompt

