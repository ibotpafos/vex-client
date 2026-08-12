# VEX Auth Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dense sign-in form with a two-step VEX auth entry while preserving the existing email OTP, website PKCE, and biometric flows.

**Architecture:** Keep authentication transport and session code unchanged. Add a small pure screen-step helper for the welcome/email state, then let `SignInScreen` render the appropriate native layout. The existing `OTPCodeInput` remains the shared visual code-entry control.

**Tech Stack:** Expo Router, React Native, TypeScript, existing VEX UI primitives, Android local APK verification.

## Global Constraints

- Do not add Google, Apple, phone, or any unimplemented identity provider.
- Do not change `/v1/auth/*` backend contracts.
- Do not log email addresses, one-time codes, or session credentials.
- Do not deploy or publish an app artifact.

---

### Task 1: Auth entry state helper

**Files:**
- Create: `src/auth/authEntry.ts`
- Modify: `tests/run-unit-tests.ts`

**Interfaces:**
- Produces: `type AuthEntryStep = 'welcome' | 'email'` and `authEntryStepAfterBack(hasPendingChallenge: boolean): AuthEntryStep`.
- Consumes: no platform or API dependencies.

- [x] **Step 1: Write the failing test**

```ts
assertEqual(authEntryStepAfterBack(false), 'welcome');
assertEqual(authEntryStepAfterBack(true), 'welcome');
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm run test:unit`

Expected: FAIL because `authEntryStepAfterBack` does not exist.

- [x] **Step 3: Write minimal implementation**

```ts
export type AuthEntryStep = 'welcome' | 'email';

export function authEntryStepAfterBack(_hasPendingChallenge: boolean): AuthEntryStep {
  return 'welcome';
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `npm run test:unit`

Expected: PASS.

### Task 2: Two-step sign-in screen

**Files:**
- Modify: `src/screens/sign-in-screen.tsx`
- Test: `tests/run-unit-tests.ts`

**Interfaces:**
- Consumes: `AuthEntryStep`, existing `requestEmailOTP`, `OTPCodeInput`, `handleWebAuthStart`, and biometric handlers.
- Produces: a welcome screen and an email/OTP screen without a login/register selector.

- [x] **Step 1: Add a failing state-helper assertion for back behavior**

```ts
assertEqual(authEntryStepAfterBack(false), 'welcome');
assertEqual(authEntryStepAfterBack(true), 'welcome');
```

- [x] **Step 2: Render the welcome state**

Add a logo, `Давайте подключимся`, and a single `Войти или создать аккаунт` button that selects the email state.

- [x] **Step 3: Render the email state**

Remove the mode segment. Add a back button, email field, `Продолжить`, existing website auth button, and existing biometric button where available. On challenge creation, preserve the six-cell code UI and resend action.

- [x] **Step 4: Preserve error semantics**

Keep the cooldown as an `authNotice`; preserve other API errors. Do not render or log an email beyond the text input itself.

- [x] **Step 5: Verify source checks**

Run: `npm run test:unit && npm run typecheck && npm run lint && git diff --check`

Expected: PASS without warnings or diff whitespace errors.

### Task 3: Android artifact and device verification

**Files:**
- No source changes expected.

- [x] **Step 1: Build the local app**

Run: `NODE_ENV=production VEX_DEBUG_APPLICATION_ID_SUFFIX=.dev ./gradlew :app:assembleLocal -PreactNativeArchitectures=arm64-v8a --console=plain`

Expected: local APK generated at `android/app/build/outputs/apk/local/app-local.apk`.

- [x] **Step 2: Install on the attached test Android**

Run: `adb -s 4ba9ae7d9805 install -r android/app/build/outputs/apk/local/app-local.apk`

Expected: `Success`.

- [x] **Step 3: Manually verify unauthenticated states**

Verify: welcome screen → email screen → back returns to welcome; website button opens the VEX website; no crash in logcat.

- [ ] **Step 4: Verify code entry with a real delivery only if explicitly initiated by the owner**

Verify: six cells focus, accept pasted digits, and display the correct resend state. Do not send an unsolicited email.
