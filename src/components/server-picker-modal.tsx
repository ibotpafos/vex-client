import React from "react";
import { Platform } from "react-native";
import {
  BottomSheet,
  Column,
  Host,
  Text as UniversalText,
} from "@expo/ui";
import {
  ListItem as ComposeListItem,
  ModalBottomSheet,
  Text as ComposeText,
  type ModalBottomSheetRef,
} from "@expo/ui/jetpack-compose";
import { clickable, testID as composeTestID } from "@expo/ui/jetpack-compose/modifiers";
import type { VpnLocation } from "@/api/vexApi";
import type { ServerSelectionMode } from "@/vpn/serverSelection";
import {
  locationStatusText,
} from "../screens/home-screen-helpers";
import {
  groupVpnLocationsByCountry,
  serverCountLabel,
  serverPickerLocationTitle,
  serverPickerRowPresentation,
} from "../screens/server-picker-interactions";

export interface ServerPickerModalProps {
  countryTitle?: string;
  isVpnBusy: boolean;
  isRefreshing?: boolean;
  locations: VpnLocation[];
  refreshError?: unknown;
  selectedLatencyText?: string;
  selectionMode: ServerSelectionMode;
  selectedLocationId: string;
  visible: boolean;
  onAutoSelect: () => void;
  onClose: () => void;
  onSelect: (locationId: string) => void;
  onRetry?: () => void;
}

export const ServerPickerModal = React.memo(function ServerPickerModal({
  visible,
  ...props
}: ServerPickerModalProps) {
  if (Platform.OS === "android") {
    return <AndroidServerPickerSheet {...props} visible={visible} />;
  }

  if (!visible) {
    return null;
  }

  return (
    <BottomSheet
      isPresented={visible}
      onDismiss={props.onClose}
      snapPoints={["full"]}
      testID="server-picker-sheet"
    >
      <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
        <ServerPickerBody {...props} />
      </Host>
    </BottomSheet>
  );
});

function AndroidServerPickerSheet({ visible, ...props }: ServerPickerContentProps & { visible: boolean }) {
  const sheetRef = React.useRef<ModalBottomSheetRef>(null);
  const [isMounted, setIsMounted] = React.useState(visible);

  React.useEffect(() => {
    if (visible) {
      setIsMounted(true);
      return;
    }
    sheetRef.current?.hide().finally(() => setIsMounted(false));
  }, [visible]);

  if (!isMounted) {
    return null;
  }

  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.androidSheetHost} pointerEvents="none">
      <ModalBottomSheet
        containerColor="#041315"
        contentColor="#F4FCFD"
        onDismissRequest={() => {
          setIsMounted(false);
          props.onClose();
        }}
        ref={sheetRef}
        showDragHandle
        skipPartiallyExpanded
      >
        <ServerPickerBody {...props} />
      </ModalBottomSheet>
    </Host>
  );
}

type ServerPickerContentProps = Omit<ServerPickerModalProps, "visible">;

export const ServerPickerContent = React.memo(function ServerPickerContent(props: ServerPickerContentProps) {
  return (
    <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
      <ServerPickerBody {...props} />
    </Host>
  );
});

function ServerPickerBody({
  isVpnBusy,
  locations,
  selectedLatencyText,
  selectedLocationId,
  selectionMode,
  onAutoSelect,
  onRetry,
  onSelect,
  isRefreshing,
  refreshError,
}: ServerPickerContentProps) {
  const countryGroups = React.useMemo(() => groupVpnLocationsByCountry(locations), [locations]);
  const [expandedCountryCode, setExpandedCountryCode] = React.useState<string | null>(null);

  return (
    <Column spacing={4} style={styles.content} testID="server-picker-sheet">
      <UniversalText textStyle={styles.eyebrow}>ЛОКАЦИЯ</UniversalText>
      <UniversalText textStyle={styles.title}>Выберите сервер</UniversalText>
      <UniversalText textStyle={styles.subtitle}>
        VEX выберет лучший сервер автоматически. Страну и конкретный сервер можно указать вручную.
      </UniversalText>
      <Column spacing={0}>
        <ServerPickerRow
          leading="↻"
          onPress={isVpnBusy || locations.length === 0 ? undefined : onAutoSelect}
          supportingText="Лучший сервер среди всех стран"
          testID="server-picker-auto"
          trailing={selectionMode === "auto" ? "✓" : undefined}
        >
          Автоматически
        </ServerPickerRow>
        {countryGroups.map((group) => {
          const countrySelected = selectionMode === "manual"
            && group.locations.some((location) => location.id === selectedLocationId);
          const expanded = expandedCountryCode === group.countryCode;
          const bestLocation = group.bestLocation;
          const bestPresentation = bestLocation ? serverPickerRowPresentation(bestLocation, {
            busy: isVpnBusy,
            selected: bestLocation.id === selectedLocationId,
            selectedLatencyText,
          }) : null;
          const serverCount = group.locations.length;
          const bestLocationOrdinal = bestLocation
            ? group.locations.findIndex((location) => location.id === bestLocation.id) + 1
            : undefined;
          return (
            <Column key={group.countryCode} spacing={0} style={styles.countryCard}>
              <ServerPickerRow
                leading={group.flagEmoji || group.countryCode}
                onPress={!bestLocation || bestPresentation?.disabled ? undefined : () => {
                  if (serverCount === 1) {
                    onSelect(bestLocation.id);
                    return;
                  }
                  setExpandedCountryCode(expanded ? null : group.countryCode);
                }}
                supportingText={bestLocation
                  ? `${serverCountLabel(serverCount)} · лучший ${serverPickerLocationTitle(bestLocation, bestLocationOrdinal)} · ${bestPresentation?.latency}`
                  : "Нет доступных серверов"}
                testID={`server-picker-country-${group.countryCode.toLowerCase()}`}
                trailing={serverCount > 1
                  ? `${countrySelected ? "✓  " : ""}${expanded ? "⌃" : "⌄"}`
                  : countrySelected ? "✓" : undefined}
              >
                {group.title}
              </ServerPickerRow>
              {expanded ? group.locations.map((location, index) => {
                const selected = selectionMode === "manual" && location.id === selectedLocationId;
                const presentation = serverPickerRowPresentation(location, {
                  busy: isVpnBusy,
                  selected,
                  selectedLatencyText,
                });
                return (
                  <ServerPickerRow
                    key={location.id}
                    leading={location.id === bestLocation?.id ? "★" : "•"}
                    onPress={presentation.disabled ? undefined : () => onSelect(location.id)}
                    supportingText={`${locationStatusText(location)} · ${presentation.latency}${location.id === bestLocation?.id ? " · лучший" : ""}`}
                    testID={`server-picker-${location.id}`}
                    trailing={presentation.selected ? "✓" : undefined}
                  >
                    {serverPickerLocationTitle(location, index + 1)}
                  </ServerPickerRow>
                );
              }) : null}
            </Column>
          );
        })}
        {locations.length === 0 ? (
          <ServerPickerRow
            leading="↻"
            onPress={isVpnBusy || isRefreshing ? undefined : onRetry}
            supportingText={refreshError ? "Не удалось обновить список" : "Список серверов пока пуст"}
            testID="server-picker-retry"
          >
            {isRefreshing ? "Обновляем…" : "Повторить"}
          </ServerPickerRow>
        ) : null}
      </Column>
    </Column>
  );
}

function ServerPickerRow({
  children,
  leading,
  onPress,
  supportingText,
  testID,
  trailing,
}: {
  children: string;
  leading: string;
  onPress?: () => void;
  supportingText: string;
  testID: string;
  trailing?: string;
}) {
  return (
    <ComposeListItem
      colors={styles.rowColors}
      modifiers={[composeTestID(testID), ...(onPress ? [clickable(onPress)] : [])]}
      shadowElevation={0}
      tonalElevation={0}
    >
      <ComposeListItem.LeadingContent><ComposeText>{leading}</ComposeText></ComposeListItem.LeadingContent>
      <ComposeListItem.HeadlineContent><ComposeText>{children}</ComposeText></ComposeListItem.HeadlineContent>
      <ComposeListItem.SupportingContent><ComposeText>{supportingText}</ComposeText></ComposeListItem.SupportingContent>
      {trailing ? (
        <ComposeListItem.TrailingContent><ComposeText>{trailing}</ComposeText></ComposeListItem.TrailingContent>
      ) : null}
    </ComposeListItem>
  );
}

const styles = {
  androidSheetHost: {
    position: "absolute" as const,
  },
  content: {
    backgroundColor: "#041315",
    paddingBottom: 8,
    paddingHorizontal: 20,
    paddingTop: 20,
  },
  countryCard: {
    borderColor: "rgba(103,232,249,0.12)",
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 8,
    overflow: "hidden" as const,
  },
  eyebrow: {
    color: "#67E8F9",
    fontSize: 12,
    fontWeight: "700" as const,
    letterSpacing: 1.2,
  },
  empty: {
    color: "#A7B9BD",
    fontSize: 14,
    lineHeight: 20,
    paddingHorizontal: 16,
    paddingVertical: 20,
  },
  host: {
    flex: 1,
  },
  rowColors: {
    containerColor: "#041315",
    contentColor: "#F4FCFD",
    leadingContentColor: "#67E8F9",
    supportingContentColor: "#A7B9BD",
    trailingContentColor: "#67E8F9",
  },
  subtitle: {
    color: "#A7B9BD",
    fontSize: 14,
    lineHeight: 20,
  },
  title: {
    color: "#F4FCFD",
    fontSize: 24,
    fontWeight: "800" as const,
  },
};
