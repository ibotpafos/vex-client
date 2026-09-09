import { Redirect, Stack } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Animated, StyleSheet, View } from 'react-native';

import type { VpnLocation } from '@/api/vexApi';
import { LocationHomeHero } from '@/components/location-home-hero';
import { ServerPickerModal } from '@/components/server-picker-modal';
import type { ConnectionPhase } from '@/screens/home-screen-helpers';

const previewLocations: VpnLocation[] = [
  { id: 'nl-amsterdam-1', countryCode: 'NL', city: 'Амстердам 1', flagEmoji: '🇳🇱', availability: 'available', status: 'healthy', healthyNodes: 1, latencyMs: 42 },
  { id: 'nl-amsterdam-2', countryCode: 'NL', city: 'Амстердам 2', flagEmoji: '🇳🇱', availability: 'available', status: 'healthy', healthyNodes: 1, latencyMs: 35 },
  { id: 'de-frankfurt-1', countryCode: 'DE', city: 'Франкфурт 1', flagEmoji: '🇩🇪', availability: 'available', status: 'healthy', healthyNodes: 1, latencyMs: 49 },
  { id: 'de-frankfurt-2', countryCode: 'DE', city: 'Франкфурт 2', flagEmoji: '🇩🇪', availability: 'available', status: 'healthy', healthyNodes: 1, latencyMs: 31 },
  { id: 'fi-helsinki-1', countryCode: 'FI', city: 'Хельсинки 1', flagEmoji: '🇫🇮', availability: 'available', status: 'healthy', healthyNodes: 1, latencyMs: 56 },
];

export default function DesignPreviewScreen() {
  const [connectionPhase, setConnectionPhase] = useState<ConnectionPhase>('idle');
  const [location, setLocation] = useState(previewLocations[3]);
  const [pickerVisible, setPickerVisible] = useState(false);
  const [selectionMode, setSelectionMode] = useState<'auto' | 'manual'>('auto');
  const pulseProgress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (connectionPhase !== 'connecting') return;
    const timer = setTimeout(() => setConnectionPhase('connected'), 1_100);
    return () => clearTimeout(timer);
  }, [connectionPhase]);

  if (!__DEV__) {
    return <Redirect href="/" />;
  }

  return (
    <View style={styles.screen}>
      <Stack.Screen options={{ headerShown: false }} />
      <View style={styles.phoneViewport}>
        <LocationHomeHero
          connectionPhase={connectionPhase}
          latencyText={`${location.latencyMs} мс`}
          location={location}
          onLocationPress={() => setPickerVisible(true)}
          onPowerPress={() => setConnectionPhase((phase) => phase === 'connected' ? 'idle' : 'connecting')}
          onSettingsPress={() => undefined}
          powerButtonDisabled={false}
          pulseProgress={pulseProgress}
          selectionMode={selectionMode}
        />
        <ServerPickerModal
          isVpnBusy={false}
          locations={previewLocations}
          selectedLatencyText={`${location.latencyMs} мс`}
          selectionMode={selectionMode}
          selectedLocationId={location.id}
          visible={pickerVisible}
          onAutoSelect={() => {
            setLocation(previewLocations[3]);
            setSelectionMode('auto');
            setPickerVisible(false);
          }}
          onClose={() => setPickerVisible(false)}
          onSelect={(locationId) => {
            setLocation(previewLocations.find((candidate) => candidate.id === locationId) ?? previewLocations[0]);
            setSelectionMode('manual');
            setPickerVisible(false);
          }}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    alignItems: 'center',
    backgroundColor: '#01090C',
    flex: 1,
  },
  phoneViewport: {
    flex: 1,
    maxWidth: 430,
    overflow: 'hidden',
    width: '100%',
  },
});
