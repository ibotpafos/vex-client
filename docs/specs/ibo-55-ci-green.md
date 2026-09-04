# IBO-55 CI-green specification

## Objective
Make the native-mobile CI workflow execute its declared gates successfully on clean GitHub-hosted runners.

## Scope
Only `.github/workflows/native-mobile-ci.yml` and tests/checks directly required for its deterministic runner setup.

## Scenarios
- Android debug build finds the debug keystore.
- iOS dependency installation starts from no stale generated Pods state.
- EAS profile validation does not require interactive account credentials.

## Invariants
- No signing credentials or secrets are committed.
- Existing mobile build commands remain unchanged after setup.
- CI continues to validate Android, iOS, native macOS and shared Expo targets.

## Acceptance criteria
1. Static workflow checks prove the three preconditions above.
2. Local workflow-oriented tests pass.
3. Push triggers GitHub Actions and all jobs on PR #18 pass.
