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

Mobile result: passed

---

# VEX macOS photo locations — design QA

Date: 2026-09-09

## Comparison target

- Source visual truth: `docs/design-qa/macos-photo-locations/source-option-3.png` (1536 × 1024 px).
- Final implementation: `docs/design-qa/macos-photo-locations/implementation-polish-4.png` (1840 × 1160 px).
- Final normalized comparison: `docs/design-qa/macos-photo-locations/comparison-polish-4.png`; both panes normalized to the same 1840 × 1160 px viewport before side-by-side review.
- State: authenticated home preview, disconnected, Germany selected.

## Findings

- No actionable P0, P1, or P2 differences remain after the responsive-grid correction.
- [P3] The live hero uses the production Frankfurt crop, whose tallest tower is centered more closely than in the concept image. Text and controls remain legible and the real asset framing is accepted.

## Fidelity surfaces

- Typography: system font, hierarchy, weights, and Russian copy match the source closely.
- Layout: 294 pt hero, restrained connect control, 136 pt photographic cards, explicit three-column sizing, and bottom navigation rhythm match the source.
- Colors: dark teal, cyan state accent, and restrained overlays match the source.
- Image quality: purpose-generated wide Frankfurt, Helsinki, and Amsterdam assets are sharp and correctly cropped; no placeholder or synthetic code artwork is used.
- Copy: country names, node counts, latency, connection state, and best-server label match the intended product behavior.

## Interaction evidence

- Country cards are real buttons. The packaged `.app` was exercised: selecting Germany changed the hero photograph and selection state.
- Clicking the already-selected Finland card opened the existing server sidebar, grouped by country, for manual selection.
- Duplicate Germany servers collapse into one home card while remaining individually selectable in the sidebar.
- Selecting another country keeps the card order stable, preventing the pointer target from jumping after a click.
- The VPN power action remains connected to the existing helper/app-state flow.

## Comparison history

- Pass 1: found oversized/high connect control and undersized location cards.
- Fixes: reduced the power control from 152 pt to 128 pt, moved it down, and increased the photo strip from 106 pt to 124 pt.
- Pass 2: `comparison-pass-2.png` confirms the hero hierarchy and location-strip proportions now track the source; no P0/P1/P2 differences remain.
- Polish pass 3 found the real cause of the visibly merged cards: an unconstrained intrinsic image width escaped the relative scroll frame. Each card now receives an explicit measured width, so all three columns and both 12 pt gaps fit exactly.
- Polish pass 4 removed redundant idle helper copy, reduced the orbit field, aligned hero/card radii and selection treatment, and confirmed the final visual in `implementation-polish-4.png`.
- Focused crop: not required because the normalized 1840 × 580 combined comparison keeps the hero typography, card copy, image crops, borders, and navigation controls readable at 1×.

## Build verification

- Universal production `.app` build completed for arm64 and x86_64.
- `codesign --verify --deep --strict macos-native/build/VEXNativeMac.app` passed.
- Photo-render contract passed with 5.56% warm photographic coverage versus 0.13% before implementation.
- Country-grouping/layout contract passed: one home card per country, stable country order, selected manual server preserved, and three cards fit with two exact 12 pt gaps.
- `git diff --check` passed.
- Full `swift test` is locally blocked before test execution because this Mac only has Command Line Tools and its Swift 6.3 toolchain does not provide the legacy `XCTest` module used by the existing test targets. This is an environment gate, not a test assertion failure.

## Country transition polish

- Hero photographs crossfade over 450 ms with a restrained 1.025 insertion scale; the fixed readability gradients no longer animate or double-darken during the transition.
- Country summary text uses the same timing and a short vertical fade so the label stays synchronized with the photograph.
- Card border, shadow, and selected chevron settle over 240 ms while the country order remains fixed.
- Reduce Motion uses an 80 ms opacity-only photo change and an effectively immediate 10 ms card-state update, with no scale or movement.
- Motion timing contract passed and the final static frame remains visually unchanged in `docs/design-qa/macos-photo-locations/implementation-motion-final.png`.

final result: passed
