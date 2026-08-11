# Sign-in screen design

## Goal

Make the unauthenticated entry flow feel like one focused native experience:
welcome first, then a full-height bottom sheet for email sign-in. Keep the
existing email OTP, web sign-in, PKCE callback, biometric recovery, and error
handling behavior intact.

## Flow

1. The welcome screen shows the VEX wordmark, one short explanatory sentence,
   and a single primary button pinned above the bottom safe area.
2. Tapping the primary button opens the sign-in form from the bottom.
3. On Android, the form uses a dark Material bottom-sheet container with an
   explicit dark container and scrim color. On other platforms it uses the
   Expo UI Universal bottom sheet.
4. The sheet always opens at full height. Android Back, an outside tap, or the
   in-sheet back control return to welcome without altering the auth state.
5. The email field, feedback text, and primary action remain visible when the
   keyboard appears. OTP is rendered as six native-hosted cells after a code
   has been sent.

## Visual hierarchy

- Welcome: restrained centered brand content and one bottom-aligned CTA.
- Sheet: small drag handle, compact back action, one plain-language heading,
  email field, contextual feedback, and a single dominant action.
- Secondary web or biometric actions remain visually secondary.
- Use the existing VEX dark palette. Do not add image cards, gradients, or
  decorative surfaces.

## Compatibility and verification

- Use Expo UI `Host`/Universal components for the screen tree.
- The Android sheet may use Expo UI's Jetpack Compose sheet leaf solely to set
  `containerColor` because the current Universal Android wrapper does not
  propagate the enclosing Host color to its Material modal window.
- Verify with one installed Expo development build and `expo start --dev-client`:
  initial screen, open, Back close, repeat open, keyboard, email validation,
  and OTP layout.
- Rebuild only if a native dependency or native configuration changes.
