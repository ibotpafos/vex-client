import type { VpnLocation } from '../api/types';
import type { ServerSelectionMode } from '../vpn/serverSelection';

export type ServerPickerLocationRow = {
  location: VpnLocation;
  selected: boolean;
  testID: string;
};

export function serverPickerLocationRows(
  locations: VpnLocation[],
  selectionMode: ServerSelectionMode,
  selectedLocationId: string,
): ServerPickerLocationRow[] {
  return locations.map((location) => ({
    location,
    selected: selectionMode === 'manual' && location.id === selectedLocationId,
    testID: `server-picker-${location.id}`,
  }));
}
