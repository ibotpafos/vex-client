import { StatusBar } from 'expo-status-bar';
import { useLocalSearchParams } from 'expo-router';

import { ServerPickerContent } from '@/components/server-picker-modal';
import { useVpnConnectionContext } from '@/vpn/vpn-connection-context';

export default function ServerPickerScreen() {
  const params = useLocalSearchParams<{ activeLatencyText?: string; activeLocationId?: string }>();
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
        activeLatencyText={params.activeLatencyText}
        activeLocationId={params.activeLocationId}
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
