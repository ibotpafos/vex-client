import { vexTheme } from '@/ui/vex-theme';
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
      <Host colorScheme="dark" seedColor={vexTheme.colors.accent} style={styles.host} useViewportSizeMeasurement>
        <Column spacing={16} style={styles.panel}>
          <Spacer flexible />
          <UniversalText textStyle={styles.title}>{update.currentBuildBlocked ? 'Сборка отозвана' : update.required ? 'Нужно обновить VEX' : 'Доступно обновление'}</UniversalText>
          <UniversalText textStyle={styles.text}>
            {update.currentBuildBlocked
              ? 'Установите стабильную версию: текущая сборка не поддерживается.'
              : update.required
                ? 'Версия не поддерживается. Обновите VEX, чтобы продолжить работу.'
                : 'Доступна новая версия VEX VPN для iPhone.'}
          </UniversalText>
          {update.changelog ? <UniversalText textStyle={styles.notes}>{update.changelog}</UniversalText> : null}
          <List>
            <ListItem supportingText={`Новая: ${update.latestVersion} (${update.latestBuild})`}>
              Сейчас: {Application.nativeApplicationVersion || 'dev'} ({iosBuild || 0})
            </ListItem>
          </List>
          {updateError ? <UniversalText textStyle={styles.error}>{updateError}</UniversalText> : null}
          <Button style={styles.action} label={update.currentBuildBlocked ? 'Вернуться на стабильную' : 'Открыть обновление'} onPress={handleUpdatePress} />
          {!update.required ? <Button style={styles.action} label="Позже" onPress={() => setDismissedBuild(update.latestBuild)} variant="outlined" /> : null}
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
  action: { height: 48, borderRadius: 10 },
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
  },
  panel: {
    backgroundColor: vexTheme.colors.background,
    flex: 1,
    paddingHorizontal: 24,
    paddingVertical: 32,
  },
  title: {
    color: vexTheme.colors.text,
    fontSize: 24,
    fontWeight: '600',
    textAlign: 'center',
  },
  text: {
    color: vexTheme.colors.textSecondary,
    fontSize: 15,
    fontWeight: '400',
    lineHeight: 24,
    textAlign: 'center',
  },
  notes: {
    backgroundColor: vexTheme.colors.surface,
    borderColor: vexTheme.colors.line,
    borderRadius: 16,
    borderWidth: 1,
    color: vexTheme.colors.textSecondary,
    fontSize: 14,
    lineHeight: 20,
    padding: 12,
  },
  error: {
    color: vexTheme.colors.danger,
    fontSize: 13,
    fontWeight: '600',
    textAlign: 'center',
  },
});
