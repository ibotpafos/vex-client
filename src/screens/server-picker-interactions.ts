export type ServerPickerSource = 'all_locations' | 'carousel';

export function serverPickerActionForSource(source: ServerPickerSource): 'open_picker' | 'select' {
  return source === 'all_locations' ? 'open_picker' : 'select';
}
