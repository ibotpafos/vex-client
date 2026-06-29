import { StatusBar } from 'expo-status-bar';

import { ServerPickerContent } from '@/components/server-picker-modal';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

export default function ServerPickerScreen() {
  const {
    availableLocations,
    closeServerPicker,
    handleAutoServerSelectionPress,
    handleLocationPress,
    isVpnBusy,
    selectedLocationId,
    serverSelectionMode,
  } = useVpnConnectionContext();

  return (
    <>
      <StatusBar style="light" />
      <ServerPickerContent
        isVpnBusy={isVpnBusy}
        locations={availableLocations}
        selectionMode={serverSelectionMode}
        selectedLocationId={selectedLocationId}
        onAutoSelect={handleAutoServerSelectionPress}
        onClose={closeServerPicker}
        onSelect={handleLocationPress}
      />
    </>
  );
}
