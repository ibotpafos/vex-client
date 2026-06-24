export function isSupportSocketConnecting(
  socket: Pick<WebSocket, 'readyState'>,
  webSocketCtor: Pick<typeof WebSocket, 'CONNECTING'> | undefined = WebSocket,
): boolean {
  const connectingState = typeof webSocketCtor?.CONNECTING === 'number' ? webSocketCtor.CONNECTING : 0;
  return socket.readyState === connectingState;
}
