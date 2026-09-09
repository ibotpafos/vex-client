# VEX Mobile Visual System

Date: 2026-09-09  
Platforms: Android and iOS  
Status: approved design direction, awaiting specification review

## Goal

Bring every mobile screen into the same restrained, premium visual system introduced by the location-photo home screen. Replace the current emblem-plus-name branding with a text-only `VEX` wordmark, reduce visual noise, and make the primary flows easier to scan without changing VPN, account, update, or routing behavior.

## Scope

Included:

- sign-in and authentication entry;
- home and every VPN connection state;
- server selection;
- settings;
- Android application routing;
- update center, notices, errors, loading, empty, and success states;
- shared mobile typography, color, spacing, surfaces, controls, and wordmark;
- Android and iOS accessibility and runtime verification.

Excluded:

- Windows, macOS, web, and website redesign;
- VPN protocol, connection state machine, authentication API, billing, or backend changes;
- navigation restructuring or new product functionality;
- production publication or store rollout.

## Design direction

The product should feel calm, direct, and trustworthy. The home screen remains cinematic and location-led. Utility screens use a solid deep-navy background with restrained translucent surfaces, clear grouping, and native-feeling controls. Cyan is reserved for the primary action and focus; mint indicates a protected connection. Decorative containers, duplicated labels, and oversized iconography are removed.

The experience keeps one dominant action per screen. Secondary actions are visually quieter but remain discoverable and accessible.

## Text-only wordmark

`VEX` becomes the only visible header brand. The shield/emblem is removed from in-app headers and sign-in content.

The wordmark is rendered as live text rather than a raster asset so it stays sharp at every density, supports accessibility settings, and cannot show image-generation spelling artifacts. It uses uppercase letters, medium-bold geometric system typography, generous tracking, and optical centering. The component exposes compact and display sizes while preserving one fixed letter rhythm and white foreground color.

The wordmark is not placed inside a badge, pill, circle, or glass panel. On photographic backgrounds it receives only the existing contrast treatment of the screen, not its own backdrop.

## Shared visual system

### Color

- Canvas: deep blue-green `#041315`.
- Elevated surface: near-black teal with subtle transparency.
- Primary foreground: cool white `#F1FBFC`.
- Secondary foreground: muted blue-gray `#A7B9BD`.
- Accent/action: cyan in the existing VEX family.
- Protected/success: mint green.
- Warning and error: warm amber and coral, used only for actionable states.

Photography is limited to the home screen and location previews. A dark overlay must guarantee readable status, control, and destination text across every crop.

### Typography and spacing

- One mobile type scale: wordmark, screen title, section title, row title, body, supporting text, metadata.
- Screen gutters remain consistent across all routes.
- Large vertical gaps separate conceptual groups; small gaps relate labels to their supporting values.
- Text should not repeat information already communicated by state, selection, or a native switch.

### Surfaces and controls

- Use full-width grouped rows for settings and lists instead of a stack of individually outlined cards.
- Use one corner-radius family and one divider treatment.
- Primary buttons are filled; secondary buttons are quiet or outlined; destructive actions are text-led until confirmation.
- Retain native switches, text inputs, sheets, safe areas, status bars, and platform navigation behavior.
- Icons support navigation and meaning but never replace visible action labels in core flows.

## Shared component boundaries

Create small presentation components that do not own product state:

- `VexWordmark`: text-only brand in compact and display sizes.
- `MobileScreenScaffold`: safe area, background, status bar, and consistent horizontal gutters.
- `MobileScreenHeader`: back action, centered title or wordmark, optional trailing action.
- `VexSection`: section label and grouped surface.
- `VexSettingsRow`: icon, title, supporting text/value, and switch or disclosure accessory.
- `VexStateNotice`: compact loading, warning, error, and success feedback.
- shared mobile tokens for type, spacing, radius, surface, and semantic colors.

Existing screen containers continue to own data fetching, navigation, mutations, and toasts. The new components receive values and callbacks only. This keeps the visual rewrite isolated from connection and account logic.

## Screen designs

### Sign-in

- Text-only `VEX` wordmark at the top of the primary content stack.
- One concise promise: private connection without setup complexity.
- One primary button: `Войти или создать аккаунт`.
- Secondary explanatory text is limited to what is required before opening browser authentication.
- Loading, callback, cancellation, and error states stay in the same layout so the screen does not jump.

### Home

- Full-bleed selected-location photograph with a reliable dark contrast overlay.
- Centered text-only wordmark and lightweight connection status.
- One large central connect control with distinct disconnected, connecting, connected, disconnecting, and blocked states.
- Destination row remains the only location-selection entry point.
- Settings and update actions stay compact and do not compete with connection.
- Errors and key-rotation notices appear near the action they affect, never as permanent decorative cards.

### Server selection

- Present as a platform-appropriate sheet/modal using the same header and surface tokens.
- Put `Лучший сервер` first, with its selection state and live latency.
- List locations using country identity, city/country copy, latency, availability, and current-selection feedback.
- Keep rows easy to tap; unavailable and busy states explain why selection cannot proceed.
- Preserve the existing selection and auto-selection callbacks unchanged.

### Settings

- Remove the oversized version hero panel.
- Group rows into `Подключение`, `Маршрутизация`, `Интерфейс`, and `Аккаунт и помощь`.
- Put the current value next to the setting or in its trailing accessory; keep supporting text to one or two lines.
- Version, build, channel, core, and policy details move into a quiet `О приложении` footer/group.
- Sign-out remains separated from routine settings and receives confirmation only if the existing flow already requires it.

### Applications through VPN

- Keep Android-only behavior.
- Show the `Все приложения`/`Выбранные` mode as a compact two-option control.
- Search remains directly above the list.
- Each app row shows the native app identity when available, readable name, package metadata, and an explicit selected state.
- Loading, empty search, load failure, and save failure are visually consistent with the shared state notice.

### Update center

- Lead with the update status and required action, not a metadata list.
- Show current and available versions as compact supporting information.
- Keep `Проверить` secondary and the install/restart/store action primary.
- Changelog is readable but visually subordinate.
- Mandatory-update overlays reuse the same status and button components so the experience does not look like another product.

## Data flow and behavior

No business behavior changes. Existing hooks and contexts remain the source of truth:

- VPN state and actions continue through `useVpnConnectionContext`;
- settings continue through `useVexSettings` and existing native preference APIs;
- application routing keeps its current queued persistence behavior;
- update state continues through the existing mobile update components;
- authentication continues through the existing browser/callback flow.

Presentation components must not copy server lists, connection state, or settings into a second long-lived state. Temporary modal snapshots may remain where they prevent visible background mutation during a selection flow.

## Error handling

- Preserve existing errors and recovery actions; rewrite only presentation and concise copy.
- Every asynchronous primary action exposes busy and disabled states.
- Failures remain local to the affected flow and are also announced to accessibility services when actionable.
- Long technical details are excluded from normal screens; user-facing messages say what happened and what to do next.
- Mandatory update, missing servers, expired keys, and revoked entitlement remain blocking where current product logic marks them blocking.

## Accessibility

- All interactive controls retain explicit roles, labels, states, and minimum touch targets.
- Text-only branding is not announced redundantly when the screen title already names VEX.
- Dynamic type may wrap supporting text without clipping controls.
- Contrast is checked on every location photograph and semantic state.
- Focus order follows visual order across sign-in, home, sheets, settings, and application selection.
- Reduced-motion preferences suppress nonessential pulses while preserving state feedback.

## Verification and acceptance

Implementation is complete only when:

- unit tests, TypeScript, lint, and existing VPN contract checks pass;
- Android and iOS Expo exports pass;
- every affected route is visually inspected at a representative phone viewport;
- primary interactions and loading/error/empty states are exercised;
- a physical Android device passes launch, sign-in, server selection, real VPN connect, handshake, DNS, HTTPS traffic, disconnect, and crash-log checks;
- accessibility nodes and labels are confirmed for primary controls;
- `design-qa.md` compares final captures with the approved clean direction and reports `final result: passed`;
- the repository version mismatch with the remote mandatory-update gate is reported as a release gate rather than hidden by UI work.

## Delivery order

1. Introduce shared tokens, scaffold, header, wordmark, rows, and state notices.
2. Replace emblem branding and align sign-in and home.
3. Restyle server selection and settings.
4. Restyle Android application routing and update center.
5. Verify all visual states, exports, and physical Android VPN behavior.

This sequence keeps each step reviewable and leaves the existing data and VPN layers untouched.
