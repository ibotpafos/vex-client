export type ServerPickerSource = 'all_locations' | 'carousel';

export function serverPickerActionForSource(_source: ServerPickerSource): 'open_picker' {
  return 'open_picker';
}
