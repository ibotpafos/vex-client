# Sign-in Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a polished native VEX welcome and full-height sign-in bottom sheet without changing authentication behavior.

**Architecture:** `UniversalSignInWelcome` owns the unauthenticated welcome composition. `SignInScreen` owns the auth state and renders the form in an Expo Universal bottom sheet on iOS and an Expo Jetpack Compose sheet leaf on Android solely to set the current wrapper's missing modal colors.

**Tech Stack:** Expo Router, Expo UI Universal, Expo UI Jetpack Compose, React Native, TypeScript, Expo development build.

## Global Constraints

- Keep email OTP, website PKCE callback, biometric recovery, resend, and errors unchanged.
- Use the VEX dark palette; do not add cards, gradients, or image backgrounds.
- Iterate with one installed development build and `npx expo start --dev-client`.
- Rebuild only after native dependency or configuration changes.
- Verify open, Back close, repeat open, keyboard, validation, and OTP on Android API 36.

---

### Task 1: Refine the welcome hierarchy

**Files:**
- Modify: `src/components/universal-sign-in-welcome.tsx`
- Test: Android API 36 Expo development client

**Interfaces:**
- Consumes: `onContinue: () => void`
- Produces: a full-height welcome with exactly one primary login action.

- [ ] **Step 1: Capture the current state**

Run: `adb -s emulator-5554 exec-out screencap -p > /tmp/vex-sign-in-welcome-before.png`

Expected: capture the current welcome for before/after comparison.

- [ ] **Step 2: Implement the balanced composition**

```tsx
<Column alignment="center" spacing={16} style={styles.content}>
  <Spacer flexible />
  <Text textStyle={styles.brand}>VEX</Text>
  <Text textStyle={styles.title}>Давайте подключимся</Text>
  <Text textStyle={styles.subtitle}>Войдите, чтобы получить доступ к своему VPN.</Text>
  <Spacer flexible />
  <Button label="Войти или создать аккаунт" onPress={onContinue} />
</Column>
```

- [ ] **Step 3: Verify Fast Refresh**

Run: `npx expo start --dev-client`, then launch `com.vexguard.app.debug` on API 36.

Expected: the CTA is visible above the navigation area with no APK build.

- [ ] **Step 4: Commit only the welcome file**

Run: `git add src/components/universal-sign-in-welcome.tsx && git commit -m "feat: refine VEX sign-in welcome"`

### Task 2: Polish the full-screen sheet

**Files:**
- Modify: `src/screens/sign-in-screen.tsx`
- Test: Android API 36 Expo development client

**Interfaces:**
- Consumes: `entryStep: "welcome" | "email"`, `setEntryStep`, and existing auth callbacks.
- Produces: `SignInBottomSheet({ children, isPresented, onDismiss })` with a dark full-height Android modal and Universal iOS fallback.

- [ ] **Step 1: Capture the current sheet**

Run: tap `Войти или создать аккаунт`, then `adb -s emulator-5554 exec-out screencap -p > /tmp/vex-sign-in-sheet-before.png`.

Expected: a current visual reference before layout changes.

- [ ] **Step 2: Implement the native sheet boundary**

```tsx
<ModalBottomSheet
  containerColor="#041315"
  contentColor="#E9F7F8"
  scrimColor="#00000099"
  skipPartiallyExpanded
  onDismissRequest={onDismiss}>
  <Column modifiers={[padding(20, 56, 20, 12), fillMaxHeight()]}>{children}</Column>
</ModalBottomSheet>
```

Keep one compact back action, an email field, feedback directly below it, one dominant submit action, and outlined secondary actions.

- [ ] **Step 3: Validate interactions through Metro**

Run: `adb -s emulator-5554 shell input keyevent 4`, then tap the welcome CTA again.

Expected: Back returns to welcome; tapping reopens the full-height dark sheet; focusing email leaves the field and primary action visible.

- [ ] **Step 4: Verify static correctness**

Run: `npm run typecheck && git diff --check`

Expected: both commands exit 0.

- [ ] **Step 5: Commit only the sheet file**

Run: `git add src/screens/sign-in-screen.tsx && git commit -m "feat: polish native sign-in sheet"`

### Task 3: Prove OTP and failure feedback are preserved

**Files:**
- Modify only if a regression is found: `src/screens/sign-in-screen.tsx`, `src/components/otp-code-input.tsx`, `src/auth/emailOtp.ts`
- Test: `tests/run-unit-tests.ts`, Android API 36 Expo development client

**Interfaces:**
- Consumes: `requestEmailOTP(email)` and `confirmEmailOTP(email, challengeId, code)`.
- Produces: the existing six-cell OTP, cooldown copy, and error copy without overflow.

- [ ] **Step 1: Run auth-helper tests**

Run: `npm run test:unit`

Expected: existing email/OTP helper cases pass.

- [ ] **Step 2: Validate local error presentation**

Open the sheet and tap `Продолжить` with an empty email.

Expected: `Введите email.` appears below the field and the sheet remains open.

- [ ] **Step 3: Check OTP only through an isolated non-production account**

Submit an allowed test email, then verify six cells, resend, and cooldown/error copy remain visible above the keyboard.

Expected: no customer account, production profile, or VPN configuration is used.

- [ ] **Step 4: Run final gates**

Run: `npm run typecheck && npm run test:unit && git diff --check`

Expected: all commands exit 0.
