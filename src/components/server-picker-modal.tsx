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
import { clickable } from "@expo/ui/jetpack-compose/modifiers";
import type { VpnLocation } from "@/api/vexApi";
import type { ServerSelectionMode } from "@/vpn/serverSelection";
import {
  locationLatencyText,
  locationStatusText,
  serverLocationLabel,
} from "../screens/home-screen-helpers";

export interface ServerPickerModalProps {
  isVpnBusy: boolean;
  locations: VpnLocation[];
  selectedLatencyText?: string;
  selectionMode: ServerSelectionMode;
  selectedLocationId: string;
  visible: boolean;
  onAutoSelect: () => void;
  onClose: () => void;
  onSelect: (locationId: string) => void;
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
      snapPoints={["half", "full"]}
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
  onSelect,
}: ServerPickerContentProps) {
  return (
    <Column spacing={4} style={styles.content} testID="server-picker-sheet">
      <UniversalText textStyle={styles.eyebrow}>VEX VPN</UniversalText>
      <UniversalText textStyle={styles.title}>Серверы</UniversalText>
      <UniversalText textStyle={styles.subtitle}>
        Ближайший стабильный узел для текущей сессии.
      </UniversalText>
      <Column spacing={0}>
        <ServerPickerRow
          leading="↻"
          onPress={isVpnBusy ? undefined : onAutoSelect}
          supportingText="Лучший доступный сервер"
          testID="server-picker-auto"
          trailing={selectionMode === "auto" ? "✓" : undefined}
        >
          Автоматически
        </ServerPickerRow>
        {locations.map((location) => {
          const selected = selectionMode === "manual" && location.id === selectedLocationId;
          const latency = selected && selectedLatencyText
            ? selectedLatencyText
            : locationLatencyText(location);
          return (
            <ServerPickerRow
              key={location.id}
              leading={location.flagEmoji || location.countryCode}
              onPress={isVpnBusy ? undefined : () => onSelect(location.id)}
              supportingText={`${locationStatusText(location)} · ${latency}`}
              testID={`server-picker-${location.id}`}
              trailing={selected ? "✓" : undefined}
            >
              {serverLocationLabel(location)}
            </ServerPickerRow>
          );
        })}
      </Column>
    </Column>
  );
}

function ServerPickerRow({
  children,
  leading,
  onPress,
  supportingText,
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
      modifiers={onPress ? [clickable(onPress)] : undefined}
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
  eyebrow: {
    color: "#67E8F9",
    fontSize: 12,
    fontWeight: "700" as const,
    letterSpacing: 1.2,
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
