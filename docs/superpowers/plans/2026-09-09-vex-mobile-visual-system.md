# VEX Mobile Visual System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one coherent, text-branded visual system across the VEX Android and iOS sign-in, home, server selection, settings, application routing, and update flows without changing product behavior.

**Architecture:** Add a small presentation-only mobile UI layer on top of the existing `vexTheme`, then migrate each route to those components while leaving hooks, contexts, native APIs, and navigation contracts intact. Keep deterministic visual copy and semantic-state mapping in pure functions so the existing TypeScript unit runner can verify the contract without a renderer.

**Tech Stack:** Expo 57, React Native 0.86, Expo Router, TypeScript 6, `@expo/ui`, `lucide-react-native`, existing custom TypeScript unit runner, Gradle Android build, Expo platform exports.

**Spec:** `docs/superpowers/specs/2026-09-09-vex-mobile-visual-system-design.md`

## Global Constraints

- Android and iOS only; do not alter Windows, macOS, web, or website presentation.
- Remove shield/emblem branding from in-app headers and sign-in; render `VEX` as live uppercase text.
- Preserve VPN state, authentication, settings, application-routing, update, and navigation behavior.
- Photography is limited to the home screen and location previews.
- Preserve native switches, safe areas, status bars, sheets, touch targets, accessibility roles, labels, and states.
- Keep the existing location backgrounds and semantic cyan, mint, amber, and coral state colors.
- Do not publish, deploy, or change store/release configuration.

---

### Task 1: Shared mobile visual primitives

**Files:**
- Modify: `src/ui/vex-theme.ts`
- Modify: `src/ui/vex-ui.tsx`
- Create: `src/ui/vex-mobile-visual.ts`
- Create: `src/components/vex-wordmark.tsx`
- Create: `src/components/mobile-screen-scaffold.tsx`
- Create: `src/components/vex-state-notice.tsx`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Produces: `vexMobileType`, `vexMobileSpacing`, `vexMobileSurface`, `mobileStateNoticePresentation(tone)`, `VexWordmark`, `MobileScreenScaffold`, `MobileScreenHeader`, and `VexStateNotice`.
- Consumes: existing `vexTheme`, `VexPressable`, `SafeAreaView`, and React Native primitives.

- [ ] **Step 1: Add failing visual-contract tests**

Import the pure visual mapping into `tests/run-unit-tests.ts` and add:

```ts
function runMobileVisualContractTests(): void {
  assertDeepEqual(mobileStateNoticePresentation('error'), {
    accent: '#FF9EAA',
    accessibilityRole: 'alert',
  });
  assertDeepEqual(mobileStateNoticePresentation('success'), {
    accent: '#55D6A9',
    accessibilityRole: 'text',
  });
  assertEqual(vexMobileType.wordmark.letterSpacing, 8);
  assertEqual(vexMobileType.wordmark.fontWeight, '700');
}
```

Call `runMobileVisualContractTests()` from the runner entry point.

- [ ] **Step 2: Run the focused unit suite and confirm the new import fails**

Run: `rtk npm run test:unit`  
Expected: FAIL because `@/ui/vex-mobile-visual` does not exist.

- [ ] **Step 3: Implement tokens and semantic mapping**

Create `src/ui/vex-mobile-visual.ts` with the exact exported contract:

```ts
import { vexTheme } from '@/ui/vex-theme';

export type MobileNoticeTone = 'loading' | 'warning' | 'error' | 'success';

export const vexMobileType = {
  wordmark: { fontSize: 25, fontWeight: '700' as const, letterSpacing: 8 },
  screenTitle: { fontSize: 28, fontWeight: '700' as const, letterSpacing: -0.5 },
  sectionTitle: { fontSize: 13, fontWeight: '700' as const, letterSpacing: 0.5 },
  rowTitle: { fontSize: 16, fontWeight: '600' as const },
  body: { fontSize: 15, lineHeight: 21 },
  metadata: { fontSize: 13, lineHeight: 18 },
} as const;

export const vexMobileSpacing = { screen: 24, compactScreen: 16, section: 24, row: 16 } as const;
export const vexMobileSurface = {
  background: '#041315',
  grouped: 'rgba(5, 22, 25, 0.92)',
  pressed: 'rgba(67, 217, 231, 0.09)',
  divider: 'rgba(159, 218, 223, 0.16)',
} as const;

export function mobileStateNoticePresentation(tone: MobileNoticeTone) {
  return {
    accent: tone === 'error'
      ? vexTheme.colors.danger
      : tone === 'warning'
        ? vexTheme.colors.warning
        : tone === 'success'
          ? vexTheme.colors.success
          : vexTheme.colors.accent,
    accessibilityRole: tone === 'error' ? 'alert' as const : 'text' as const,
  };
}
```

Extend `vexTheme` only with tokens required by the spec; do not duplicate color values already present.

- [ ] **Step 4: Implement shared presentation components**

`VexWordmark` accepts `{ size?: 'compact' | 'display'; accessibilityHidden?: boolean }` and renders only a `Text` node containing `VEX`. `MobileScreenScaffold` accepts `{ children; scroll?: boolean; title?: string; onBack?: () => void; trailing?: ReactNode }`. `VexStateNotice` accepts `{ message: string; tone: MobileNoticeTone }` and uses `mobileStateNoticePresentation` for accent and role.

Keep these components stateless and keep `VexScreen` backward-compatible.

- [ ] **Step 5: Run shared checks**

Run: `rtk npm run test:unit && rtk npm run typecheck`  
Expected: PASS.

- [ ] **Step 6: Commit the primitives**

```bash
rtk git add src/ui/vex-theme.ts src/ui/vex-ui.tsx src/ui/vex-mobile-visual.ts src/components/vex-wordmark.tsx src/components/mobile-screen-scaffold.tsx src/components/vex-state-notice.tsx tests/run-unit-tests.ts
rtk git commit -m "feat(mobile): add unified VEX visual primitives"
```

---

### Task 2: Text-only branding on sign-in and home

**Files:**
- Modify: `src/components/location-home-hero.tsx`
- Modify: `src/screens/home-screen.styles.ts`
- Modify: `src/screens/home-screen.tsx`
- Modify: `src/screens/sign-in-screen.tsx`
- Modify: `src/components/sign-in-bottom-sheet.tsx`
- Modify: `src/components/sign-in-bottom-sheet.android.tsx`
- Modify: `src/components/universal-sign-in-welcome.tsx`
- Modify: `src/screens/home-screen-visual.ts`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: `VexWordmark`, `VexStateNotice`, existing `homeConnectionPresentation`, existing authentication callbacks, and `useVpnConnectionContext`.
- Produces: consistent text-only branding and stable copy/state layout on sign-in and home.

- [ ] **Step 1: Add failing branding and home-state assertions**

Add a pure brand contract to `src/screens/home-screen-visual.ts` and test it:

```ts
assertDeepEqual(homeBrandPresentation(), {
  accessibilityLabel: 'VEX VPN',
  wordmark: 'VEX',
  usesEmblem: false,
});
assertEqual(homeConnectionPresentation('connected').status, 'VPN включён');
assertEqual(homeConnectionPresentation('connecting').action, 'Отменить');
```

- [ ] **Step 2: Run the unit suite and confirm the contract fails**

Run: `rtk npm run test:unit`  
Expected: FAIL because `homeBrandPresentation` is not exported.

- [ ] **Step 3: Implement the brand contract and replace emblem markup**

Implement:

```ts
export function homeBrandPresentation() {
  return { accessibilityLabel: 'VEX VPN', wordmark: 'VEX', usesEmblem: false } as const;
}
```

Delete the `vex-logo-header.png` import and the header `Image` from `LocationHomeHero`. Render `<VexWordmark accessibilityHidden />` inside the existing centered brand container. Preserve the location image, status, central action, location selector, settings/update actions, and callbacks.

- [ ] **Step 4: Align sign-in variants to the same wordmark and hierarchy**

Replace every sign-in brand node with `VexWordmark`. Use one title, one supporting sentence, and the existing `Войти или создать аккаунт` callback. Keep browser authentication, callback handling, errors, loading, and Android bottom-sheet behavior unchanged.

- [ ] **Step 5: Verify logic and platform compilation**

Run: `rtk npm run test:unit && rtk npm run typecheck`  
Expected: PASS with no emblem import from `location-home-hero.tsx` or sign-in components.

- [ ] **Step 6: Commit sign-in and home branding**

```bash
rtk git add src/components/location-home-hero.tsx src/screens/home-screen.styles.ts src/screens/home-screen.tsx src/screens/sign-in-screen.tsx src/components/sign-in-bottom-sheet.tsx src/components/sign-in-bottom-sheet.android.tsx src/components/universal-sign-in-welcome.tsx src/screens/home-screen-visual.ts tests/run-unit-tests.ts
rtk git commit -m "feat(mobile): switch VEX flows to text-only branding"
```

---

### Task 3: Server selection visual cleanup

**Files:**
- Modify: `src/components/server-picker-modal.tsx`
- Modify: `src/components/server-picker-modal.web.tsx`
- Modify: `src/screens/server-picker-screen.tsx`
- Modify: `src/screens/server-picker-interactions.ts`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: existing `ServerPickerModalProps`, `locationLatencyText`, `locationStatusText`, `serverLocationLabel`, and selection callbacks.
- Produces: `serverPickerRowPresentation(location, context)` for deterministic title, subtitle, availability, selected state, and accessibility label.

- [ ] **Step 1: Add failing row-presentation tests**

Add assertions covering automatic, selected, unavailable, and busy rows:

```ts
assertDeepEqual(serverPickerRowPresentation(locationCandidate('de'), {
  busy: false,
  selected: true,
  selectedLatencyText: '7 мс',
}), {
  accessibilityLabel: 'Германия, DE, 7 мс, выбрано',
  disabled: false,
  latency: '7 мс',
  selected: true,
});
```

- [ ] **Step 2: Run the unit suite and verify the missing export fails**

Run: `rtk npm run test:unit`  
Expected: FAIL because `serverPickerRowPresentation` is missing.

- [ ] **Step 3: Implement row presentation and the clean sheet layout**

Keep `ServerPickerModalProps` unchanged. Move display decisions into `serverPickerRowPresentation`, then render:

- a shared modal header titled `Локация`;
- one leading `Лучший сервер` row;
- grouped location rows with flag, city/country, latency/status, and explicit selected feedback;
- `VexStateNotice` when no locations are available.

Maintain Android Compose and iOS sheet ownership and all current close/select behavior.

- [ ] **Step 4: Run server-picker and type checks**

Run: `rtk npm run test:unit && rtk npm run typecheck`  
Expected: PASS.

- [ ] **Step 5: Commit server selection**

```bash
rtk git add src/components/server-picker-modal.tsx src/components/server-picker-modal.web.tsx src/screens/server-picker-screen.tsx src/screens/server-picker-interactions.ts tests/run-unit-tests.ts
rtk git commit -m "feat(mobile): simplify server selection"
```

---

### Task 4: Settings information architecture and components

**Files:**
- Create: `src/components/vex-settings-section.tsx`
- Create: `src/screens/settings-screen-copy.ts`
- Modify: `src/screens/settings-screen.tsx`
- Modify: `src/components/universal-settings-content.tsx`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: existing `useVexSettings`, `useVpnConnectionContext`, `SettingsNativeSwitch`, routes, external URL helpers, and toast behavior.
- Produces: `settingsSectionModel(platform)` and presentation components `VexSection` and `VexSettingsRow`.

- [ ] **Step 1: Add failing settings grouping tests**

Test the exact section order and Android-only routing row:

```ts
assertDeepEqual(settingsSectionModel('ios').map((section) => section.id), [
  'connection', 'routing', 'interface', 'account', 'about',
]);
assertEqual(
  settingsSectionModel('ios').flatMap((section) => section.rows).includes('applications'),
  false,
);
assertEqual(
  settingsSectionModel('android').flatMap((section) => section.rows).includes('applications'),
  true,
);
```

- [ ] **Step 2: Run the unit suite and confirm the model import fails**

Run: `rtk npm run test:unit`  
Expected: FAIL because `settings-screen-copy.ts` does not exist.

- [ ] **Step 3: Implement the settings model**

Export:

```ts
export type SettingsSectionId = 'connection' | 'routing' | 'interface' | 'account' | 'about';
export type SettingsRowId = 'automation' | 'server' | 'smart-routing' | 'anti-leak' | 'applications' | 'language' | 'dashboard' | 'support' | 'sign-out' | 'version';
export function settingsSectionModel(platform: 'android' | 'ios'): ReadonlyArray<{
  id: SettingsSectionId;
  rows: readonly SettingsRowId[];
}>;
```

Return the exact tested order and insert `applications` only for Android.

- [ ] **Step 4: Build grouped row primitives and migrate settings**

`VexSection` accepts `{ title: string; children: ReactNode }`. `VexSettingsRow` accepts `{ title; description?; value?; icon?; accessory?; onPress?; disabled?; accessibilityRole?; accessibilityState? }`.

Split the current 780-line JSX into the five model-backed groups. Remove the version hero panel; move version/build/channel/core/policy into `О приложении`. Preserve every handler, save guard, toast, switch state, Android application summary refresh, language selection, external URL, and sign-out behavior.

- [ ] **Step 5: Run the settings contract and type checks**

Run: `rtk npm run test:unit && rtk npm run typecheck`  
Expected: PASS.

- [ ] **Step 6: Commit settings**

```bash
rtk git add src/components/vex-settings-section.tsx src/screens/settings-screen-copy.ts src/screens/settings-screen.tsx src/components/universal-settings-content.tsx tests/run-unit-tests.ts
rtk git commit -m "feat(mobile): reorganize VEX settings"
```

---

### Task 5: Application routing and update center polish

**Files:**
- Create: `src/screens/mobile-utility-visual.ts`
- Modify: `src/components/universal-vpn-applications-content.tsx`
- Modify: `src/screens/vpn-applications-screen.tsx`
- Modify: `src/components/universal-update-center-content.tsx`
- Modify: `src/components/update-center.tsx`
- Modify: `src/screens/update-center-screen.tsx`
- Modify: `src/components/android-update-overlay.tsx`
- Modify: `src/components/ios-update-overlay.tsx`
- Modify: `src/components/ota-update-overlay.tsx`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: shared scaffold/header/state notice, existing application selection props, update actions, update query state, and platform overlays.
- Produces: `applicationSelectionSummary(mode, count)` and `updateStatusHierarchy(updateState)` pure presentation helpers.

- [ ] **Step 1: Add failing utility presentation tests**

```ts
assertEqual(applicationSelectionSummary('all', 0), 'Все приложения');
assertEqual(applicationSelectionSummary('selected', 3), 'Выбрано: 3');
assertDeepEqual(updateStatusHierarchy({ required: true, available: true }), {
  actionPriority: 'primary',
  tone: 'warning',
});
assertDeepEqual(updateStatusHierarchy({ required: false, available: false }), {
  actionPriority: 'secondary',
  tone: 'success',
});
```

- [ ] **Step 2: Run the unit suite and verify missing helpers fail**

Run: `rtk npm run test:unit`  
Expected: FAIL because `mobile-utility-visual.ts` does not exist.

- [ ] **Step 3: Implement helpers and application selection layout**

Keep `UniversalVpnApplicationsContentProps` unchanged. Render the existing mode callbacks as a compact two-option control, retain search above the list, show explicit selection state on each row, and route loading/empty/failure feedback through `VexStateNotice`. Preserve queued persistence and Android-only native loading.

- [ ] **Step 4: Implement update hierarchy across route and overlays**

Lead with status title/message, show versions as supporting metadata, keep `Проверить` secondary, and use the existing install/restart/store action as primary. Reuse the same status and button treatment in Android, iOS, and OTA overlays without changing update eligibility or install behavior.

- [ ] **Step 5: Run unit, type, and lint checks**

Run: `rtk npm run test:unit && rtk npm run typecheck && rtk npm run lint`  
Expected: PASS with no new lint errors.

- [ ] **Step 6: Commit utility screens**

```bash
rtk git add src/screens/mobile-utility-visual.ts src/components/universal-vpn-applications-content.tsx src/screens/vpn-applications-screen.tsx src/components/universal-update-center-content.tsx src/components/update-center.tsx src/screens/update-center-screen.tsx src/components/android-update-overlay.tsx src/components/ios-update-overlay.tsx src/components/ota-update-overlay.tsx tests/run-unit-tests.ts
rtk git commit -m "feat(mobile): unify routing and update experiences"
```

---

### Task 6: Visual QA, platform exports, and physical Android acceptance

**Files:**
- Modify: `app/design-preview.tsx`
- Modify: `app/design-preview.web.tsx`
- Modify: `design-qa.md`
- Create: `docs/design-qa/vex-mobile-system/README.md`
- Create: `docs/design-qa/vex-mobile-system/*.png`
- Modify: `docs/design-qa/vex-home-redesign/android-qa.md`

**Interfaces:**
- Consumes: all migrated routes and existing Android SDK/JDK/adb workflow.
- Produces: reproducible visual evidence, passing design report, Android/iOS export evidence, and physical Android VPN proof.

- [ ] **Step 1: Extend the design preview to every target route/state**

Add deterministic preview controls for sign-in, disconnected home, connected home, server picker, settings, application routing, update available, and update required. Preview-only state must stay inside the design-preview routes and must not enter production screen logic.

- [ ] **Step 2: Run the complete automated gate**

Run: `rtk npm run check`  
Expected: unit, AWG upstream contract, TypeScript, and lint pass; record pre-existing warnings separately from new errors.

- [ ] **Step 3: Export Android and iOS bundles**

Run Android export:

```bash
export VEX_ANDROID_EXPORT_DIR="$(mktemp -d /tmp/vex-mobile-android-export.XXXXXX)"
rtk proxy npx expo export --platform android --output-dir "$VEX_ANDROID_EXPORT_DIR"
```

Run iOS export:

```bash
export VEX_IOS_EXPORT_DIR="$(mktemp -d /tmp/vex-mobile-ios-export.XXXXXX)"
rtk proxy npx expo export --platform ios --output-dir "$VEX_IOS_EXPORT_DIR"
```

Expected: both exports complete without errors.

- [ ] **Step 4: Run visual comparison and fix all P0–P2 findings**

Capture every deterministic preview state at the same mobile viewport. Compare wordmark, hierarchy, spacing, contrast, controls, sheets, lists, copy, and state feedback against the approved clean direction. Update `design-qa.md`; repeat capture and repair until it contains `final result: passed`. Record remaining P3 refinements without blocking delivery.

- [ ] **Step 5: Build and install the Android debug candidate**

Use JDK 17 and the existing local Android SDK. Build `arm64-v8a`, install only `com.vexguard.client.debug`, and preserve `com.vexguard.app`. If the remote mandatory-update gate still requires build `1005765`, use local test-only metadata and restore `android/app/build.gradle` before recording completion.

- [ ] **Step 6: Drive physical Android E2E with UI-tree coordinates**

On the connected Xiaomi Mi A1:

1. launch the debug package;
2. capture sign-in/home UI trees and screenshots;
3. open server selection and choose a location;
4. connect using coordinates computed from the UI tree;
5. verify a fresh handshake, `tun0`, VPN DNS, validated network, HTTPS 200, and RX/TX increase;
6. inspect app logs and the crash buffer;
7. disconnect and confirm Android no longer reports VPN transport.

Save sanitized screenshots and results under `docs/design-qa/vex-mobile-system/` and update the Android QA report.

- [ ] **Step 7: Commit verification artifacts**

```bash
rtk git add app/design-preview.tsx app/design-preview.web.tsx design-qa.md docs/design-qa/vex-mobile-system docs/design-qa/vex-home-redesign/android-qa.md
rtk git commit -m "test(mobile): verify unified VEX experience"
```

---

### Task 7: Final release-readiness review

**Files:**
- Modify: `docs/design-qa/vex-mobile-system/README.md`

**Interfaces:**
- Consumes: committed implementation, automated results, exports, design QA, and physical Android evidence.
- Produces: one final local release-readiness statement with explicit remaining gates.

- [ ] **Step 1: Review the complete branch diff**

Run:

```bash
rtk git diff HEAD~6..HEAD --stat
rtk git diff HEAD~6..HEAD -- src app tests docs/design-qa
```

Confirm that no VPN, authentication, update eligibility, settings persistence, native protocol, desktop, or release behavior changed beyond the approved presentation scope.

- [ ] **Step 2: Re-run the final gate after review fixes**

Run: `rtk npm run check`  
Expected: PASS.

- [ ] **Step 3: Record release gates**

Append exact current evidence to `docs/design-qa/vex-mobile-system/README.md`: commit list, checks, Android/iOS export results, device/OS, VPN proof, crash result, repository app version, remote minimum build, and whether physical iOS acceptance is still outstanding.

- [ ] **Step 4: Commit the readiness record**

```bash
rtk git add docs/design-qa/vex-mobile-system/README.md
rtk git commit -m "docs(mobile): record VEX visual release readiness"
```
