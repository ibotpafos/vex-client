import * as Application from 'expo-application';
import { Button, Column, Host, List, ListItem, Spacer, Text as UniversalText } from '@expo/ui';
import { useCallback, useEffect, useState } from 'react';
import { Platform, StyleSheet, View } from 'react-native';
import { installManualUpdate } from '@/api/manualUpdateInstall';
import { requiresNativeUpdate } from '@/api/updatePreflight';
import { useMobileAppUpdateQuery } from '@/components/mobile-app-update-query';

const iosBuild = currentIOSBuild();

export function IOSUpdateOverlay() {
  if (Platform.OS !== 'ios') {
    return null;
  }

  return <IOSUpdateOverlayContent />;
}

function IOSUpdateOverlayContent() {
  const [updateError, setUpdateError] = useState<string | null>(null);
  const [dismissedBuild, setDismissedBuild] = useState<number | null>(null);
  const updateQuery = useMobileAppUpdateQuery('ios', iosBuild);
  const update = updateQuery.data ?? null;
  const shouldShow = Boolean(update && requiresNativeUpdate(update) && dismissedBuild !== update.latestBuild);

  useEffect(() => {
    setUpdateError(updateQuery.error ? 'Не удалось проверить обновление.' : null);
  }, [updateQuery.error]);

  const handleUpdatePress = useCallback(async () => {
    if (!update) {
      setUpdateError('Данные обновления недоступны.');
      return;
    }
    try {
      await installManualUpdate(update, 'ios');
    } catch (error) {
      setUpdateError(error instanceof Error ? error.message : 'Не удалось открыть страницу обновления.');
    }
  }, [update]);

  if (!shouldShow || !update) {
    return null;
  }

  return (
    <View style={styles.overlay}>
      <Host colorScheme="dark" seedColor="#22D3EE" style={styles.host} useViewportSizeMeasurement>
        <Column spacing={14} style={styles.panel}>
          <Spacer flexible />
          <UniversalText textStyle={styles.title}>{update.currentBuildBlocked ? 'Сборка отозвана' : update.required ? 'Нужно обновить VEX' : 'Доступно обновление'}</UniversalText>
          <UniversalText textStyle={styles.text}>
            {update.currentBuildBlocked
              ? 'Установите предложенную стабильную версию, чтобы вернуться на поддерживаемую сборку.'
              : update.required
                ? 'Эта версия VEX VPN больше не поддерживается. Обновите приложение, чтобы продолжить пользоваться сервисом.'
                : 'Доступна новая версия VEX VPN для iPhone.'}
          </UniversalText>
          {update.changelog ? <UniversalText textStyle={styles.notes}>{update.changelog}</UniversalText> : null}
          <List>
            <ListItem supportingText={`Новая: ${update.latestVersion} (${update.latestBuild})`}>
              Сейчас: {Application.nativeApplicationVersion || 'dev'} ({iosBuild || 0})
            </ListItem>
          </List>
          {updateError ? <UniversalText textStyle={styles.error}>{updateError}</UniversalText> : null}
          <Button label={update.currentBuildBlocked ? 'Вернуться на стабильную' : 'Открыть обновление'} onPress={handleUpdatePress} />
          {!update.required ? <Button label="Позже" onPress={() => setDismissedBuild(update.latestBuild)} variant="outlined" /> : null}
          <Spacer flexible />
        </Column>
      </Host>
    </View>
  );
}

function currentIOSBuild() {
  const parsed = Number.parseInt(String(Application.nativeBuildVersion ?? '0'), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

const styles = StyleSheet.create({
  overlay: {
    alignItems: 'center',
    bottom: 0,
    backgroundColor: 'rgba(2,10,11,0.88)',
    justifyContent: 'center',
    left: 0,
    paddingHorizontal: 16,
    position: 'absolute',
    right: 0,
    top: 0,
  },
  host: {
    flex: 1,
    width: '100%',
  },
  panel: {
    backgroundColor: '#041315',
    flex: 1,
    paddingHorizontal: 24,
    paddingVertical: 32,
    width: '100%',
  },
  title: {
    color: '#F4FCFD',
    fontSize: 24,
    fontWeight: '900',
    textAlign: 'center',
  },
  text: {
    color: '#C6D6D9',
    fontSize: 15,
    fontWeight: '600',
    lineHeight: 21,
    textAlign: 'center',
  },
  notes: {
    backgroundColor: 'rgba(34,211,238,0.08)',
    borderColor: 'rgba(34,211,238,0.16)',
    borderRadius: 16,
    borderWidth: 1,
    color: '#A7B9BD',
    fontSize: 14,
    lineHeight: 20,
    padding: 12,
  },
  error: {
    color: '#FF9F9F',
    fontSize: 13,
    fontWeight: '800',
    textAlign: 'center',
  },
});
