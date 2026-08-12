export type AuthEntryStep = 'welcome' | 'email';

export function authEntryStepAfterBack(_hasPendingChallenge: boolean): AuthEntryStep {
  return 'welcome';
}
