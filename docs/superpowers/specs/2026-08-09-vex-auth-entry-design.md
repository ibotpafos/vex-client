# VEX Auth Entry Design

## Goal

Make sign-in feel as focused as a modern mobile assistant: one clear entry point, then one clear credential step.

## Supported methods

- Email one-time code for sign-in and registration.
- Website sign-in through the existing PKCE flow.
- Biometric unlock only when a valid session has already been stored on the device.

Google and phone sign-in are not shown because VEX does not implement them.

## Flow

1. The initial screen shows the VEX mark, a short welcome message, and one primary action: `Войти или создать аккаунт`.
2. Tapping the action opens the email step. The screen has a back action, an email input, `Продолжить`, and `Войти через сайт` separated from the email path.
3. The backend decides whether the email belongs to an existing or new user; the UI has no `Вход / Регистрация` switch.
4. When an email challenge is created, the email step replaces its input with the six-cell code entry and a resend action.
5. A delivery cooldown is communicated as a neutral Russian notice, not an error.

## Layout and interaction rules

- Use VEX colours and typography; borrow the information hierarchy from the supplied ChatGPT references, not its branding or provider buttons.
- The welcome screen is uncluttered and does not use a large decorative container around all content.
- The email step is responsive with the keyboard visible and remains usable on Android and iOS.
- The back action returns to the welcome screen without clearing a pending email challenge; the close action is omitted because the app has no guest home route.
- Buttons use accessible names and disabled states while an auth request is in flight.

## Error handling

- Preserve API errors other than the known email delivery cooldown.
- Map the cooldown to `Код уже отправлен на email. Проверьте почту или запросите новый через минуту.`
- Do not log one-time codes, session tokens, or the entered email.

## Verification

- Unit-test the pure auth-step and one-time-code helpers.
- Typecheck and lint the Expo project.
- Build and install the local Android package on the attached device.
- Manually verify welcome, email, website sign-in, keyboard, code-cell, cooldown and back states without deploying to production.
