export class SessionOperationSupersededError extends Error {
  readonly code = 'SESSION_OPERATION_SUPERSEDED';

  constructor() {
    super('VPN operation was superseded.');
    this.name = 'SessionOperationSupersededError';
  }
}
