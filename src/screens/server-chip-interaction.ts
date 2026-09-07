export type TouchPoint = { x: number; y: number };

export function isServerChipTap(
  start: TouchPoint,
  current: TouchPoint,
  maximumMovement = 12,
): boolean {
  return Math.hypot(current.x - start.x, current.y - start.y) <= maximumMovement;
}
