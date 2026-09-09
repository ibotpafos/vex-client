export function applicationSelectionSummary(mode: 'all' | 'selected', count: number): string {
  return mode === 'selected' ? `Выбрано: ${Math.max(0, count)}` : 'Все приложения';
}

export function updateStatusHierarchy(state: { available: boolean; required: boolean }) {
  return {
    actionPriority: state.available ? 'primary' as const : 'secondary' as const,
    tone: state.required ? 'warning' as const : state.available ? 'loading' as const : 'success' as const,
  };
}
