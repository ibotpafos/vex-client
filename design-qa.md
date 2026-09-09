# VEX mobile visual system — design QA

Date: 2026-09-09

## Visual target and intentional changes

- Approved source: `/Users/ila/.codex/generated_images/01a08378-9f87-79f3-8221-9c6a62521d28/exec-f5532609-7bd9-4ae8-b94e-be3bd4fd21c9.png`.
- Local preview: `http://localhost:4173/design-preview` at a 430 × 900 CSS px mobile viewport.
- The location photograph, restrained type, translucent circular action, and bottom location control preserve the approved option 2 direction.
- The source emblem was intentionally replaced by the text-only `VEX` wordmark at the user's request.
- The standalone `VPN выключен` status was intentionally removed after annotated review; the large action now carries the full connection state.

## Final evidence

- Browser home: `docs/design-qa/vex-mobile-system/browser-home-auto-final.png`.
- Browser compact country picker: `docs/design-qa/vex-mobile-system/browser-server-picker-compact-final.png`.
- Browser expanded country card: `docs/design-qa/vex-mobile-system/browser-server-picker-expanded-final.png`.
- Physical Android home: `docs/design-qa/vex-mobile-system/android-home-auto-final.png`.
- Physical Android connected state: `docs/design-qa/vex-mobile-system/android-home-connected-final.png`.
- Physical Android separated picker: `docs/design-qa/vex-mobile-system/android-server-picker-separated.png`.
- Physical Android expanded picker: `docs/design-qa/vex-mobile-system/android-server-picker-separated-expanded.png`.

## Interaction QA

- Default location label is `Автоматически`; the best healthy location is selected by status and latency.
- Servers are grouped by country. A country with multiple servers expands in place; the best server is first and marked with a star. A one-server country selects immediately.
- Manual server selection and returning to global automatic selection both passed in the browser preview and on the physical Android device.
- The main connect action passed disconnected → connected → disconnected without a standalone status row.
- Accessibility trees expose the VEX wordmark, settings, connect action, automatic selection, country cards, and individual server choices.
- Browser console contained no errors. Existing framework warnings about web notifications, deprecated React Native shadows, and `pointerEvents` are non-blocking.

## Fidelity review

- No clipped controls, unexpected wrapping, broken radii, or unreadable foreground contrast were found at the target viewport.
- Country cards remain one row while collapsed, removing the persistent manual-selection row that consumed vertical space.
- Android country cards use native Compose list spacing: adjacent countries measured 29–32 physical px apart, while server rows inside one expanded country remain connected.
- Internal development-style server names are replaced with neutral `Сервер N` labels in the picker.
- No actionable P0, P1, or P2 visual differences remain. The heavier system-font wordmark is accepted P3 mobile readability polish.

## Build verification

- Unit and contract tests: passed.
- TypeScript: passed.
- ESLint: passed with 19 pre-existing generated-contract unused-type warnings and no errors.
- Android Expo export: passed.
- iOS Expo export: passed.
- Physical iOS visual acceptance remains a release gate; the current delivery is mobile-only and physically verified on Android.

final result: passed
