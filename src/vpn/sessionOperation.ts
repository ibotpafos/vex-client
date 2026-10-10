export class SessionOperationSupersededError extends Error {
  readonly code = 'SESSION_OPERATION_SUPERSEDED';

  constructor() {
    super('VPN operation canceled because its session changed.');
    this.name = 'SessionOperationSupersededError';
  }
}
