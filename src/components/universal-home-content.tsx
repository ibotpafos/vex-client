import { Button, Column, Host, List, ListItem, Spacer, Text } from "@expo/ui";
import type { VpnLocation } from "@/api/vexApi";
import { formatBytes, locationLatencyText, locationStatusText, serverLocationLabel } from "@/screens/home-screen-helpers";
import type { ServerSelectionMode } from "@/vpn/serverSelection";
import { useVpnTrafficStats } from "@/vpn/vpnTrafficStatsStore";

export type UniversalHomeContentProps = {
  isKeyRotationBusy: boolean;
  isVpnBusy: boolean;
  locations: VpnLocation[];
  onOpenServerPicker: () => void;
  onOpenSettings: () => void;
  onOpenUpdateCenter: () => void;
  onPowerPress: () => void;
  onRotateKeyPress: () => void;
  onSelectLocation: (locationId: string) => void;
  powerButtonDisabled: boolean;
  powerButtonText: string;
  powerSubtext: string;
  rotationRequired: boolean;
  selectedLatencyText: string;
  selectedLocationId: string;
  selectionMode: ServerSelectionMode;
  vpnError: string | null;
};

export function UniversalHomeContent({
  isKeyRotationBusy,
  isVpnBusy,
  locations,
  onOpenServerPicker,
  onOpenSettings,
  onOpenUpdateCenter,
  onPowerPress,
  onRotateKeyPress,
  onSelectLocation,
  powerButtonDisabled,
  powerButtonText,
  powerSubtext,
  rotationRequired,
  selectedLatencyText,
  selectedLocationId,
  selectionMode,
  vpnError,
}: UniversalHomeContentProps) {
  const { rxBytes, txBytes } = useVpnTrafficStats();

  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <Column spacing={8} style={styles.content}>
        <List>
          <ListItem onPress={onOpenSettings} trailing="›">VEX</ListItem>
          <ListItem onPress={onOpenUpdateCenter} supportingText="Версия приложения и системные обновления" trailing="›">
            Обновления
          </ListItem>
          <ListItem supportingText={powerSubtext}>{powerButtonText}</ListItem>
          <ListItem supportingText={formatBytes(rxBytes)}>Получено</ListItem>
          <ListItem supportingText={formatBytes(txBytes)}>Отправлено</ListItem>
        </List>

        <Text textStyle={styles.sectionTitle}>Локации</Text>
        <List testID="home-locations-list">
          {locations.map((location) => {
            const selected = location.id === selectedLocationId;
            const latency = selected ? selectedLatencyText : locationLatencyText(location);
            const detail = `${locationStatusText(location)} · ${latency}`;
            return (
              <ListItem
                key={location.id}
                leading={location.flagEmoji || location.countryCode}
                onPress={isVpnBusy ? undefined : () => onSelectLocation(location.id)}
                supportingText={detail}
                testID={`home-location-${location.id}`}
                trailing={selected ? (selectionMode === "auto" ? "Авто" : "✓") : undefined}
              >
                {serverLocationLabel(location)}
              </ListItem>
            );
          })}
          <ListItem onPress={isVpnBusy ? undefined : onOpenServerPicker} trailing="›">Все локации</ListItem>
        </List>

        {rotationRequired ? (
          <Button
            disabled={isKeyRotationBusy || isVpnBusy}
            label={isKeyRotationBusy ? "Обновляем ключи VPN…" : "Обновить ключи VPN"}
            onPress={onRotateKeyPress}
            variant="outlined"
          />
        ) : null}
        {vpnError ? <Text textStyle={styles.error}>{vpnError}</Text> : null}
        <Spacer flexible />
        <Button disabled={powerButtonDisabled} label={powerButtonText} onPress={onPowerPress} testID="vpn-power-button" />
      </Column>
    </Host>
  );
}

const styles = {
  content: {
    backgroundColor: "#041315",
    paddingBottom: 12,
  },
  error: {
    color: "#FFB4A8",
    fontSize: 14,
    lineHeight: 20,
  },
  host: {
    flex: 1,
  },
  sectionTitle: {
    color: "#F4FCFD",
    fontSize: 20,
    fontWeight: "800" as const,
  },
};
