export type TrafficDirection = 'received' | 'sent';

export function trafficSessionLabel(direction: TrafficDirection): string {
  return direction === 'received' ? 'Получено за сессию' : 'Отправлено за сессию';
}
