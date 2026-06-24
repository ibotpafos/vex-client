import * as Application from 'expo-application';
import { Shield } from 'lucide-react-native';
import React, { useCallback, useEffect, useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { installManualUpdate } from '@/api/manualUpdateInstall';
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
  const shouldShow = Boolean(update && (update.required || (update.updateAvailable && dismissedBuild !== update.latestBuild)));

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
      <View style={styles.panel}>
        <View style={styles.icon}>
          <Shield color="#031012" size={30} strokeWidth={2.6} />
        </View>
        <Text style={styles.title}>{update.currentBuildBlocked ? 'Сборка отозвана' : update.required ? 'Нужно обновить VEX' : 'Доступно обновление'}</Text>
        <Text style={styles.text}>
          {update.currentBuildBlocked
            ? 'Установите предложенную стабильную версию, чтобы вернуться на поддерживаемую сборку.'
            : update.required
            ? 'Эта версия VEX VPN больше не поддерживается. Обновите приложение, чтобы продолжить пользоваться сервисом.'
            : 'Доступна новая версия VEX VPN для iPhone.'}
        </Text>
        {update.changelog ? <Text style={styles.notes}>{update.changelog}</Text> : null}
        <View style={styles.versionRow}>
          <Text style={styles.versionText}>Сейчас: {Application.nativeApplicationVersion || 'dev'} ({iosBuild || 0})</Text>
          <Text style={styles.versionText}>Новая: {update.latestVersion} ({update.latestBuild})</Text>
        </View>
        {updateError ? <Text style={styles.error}>{updateError}</Text> : null}
        <Pressable onPress={handleUpdatePress} style={styles.primaryButton}>
          <Text style={styles.primaryText}>{update.currentBuildBlocked ? 'Вернуться на стабильную' : 'Открыть обновление'}</Text>
        </Pressable>
        {!update.required ? (
          <Pressable onPress={() => setDismissedBuild(update.latestBuild)} style={styles.secondaryButton}>
            <Text style={styles.secondaryText}>Позже</Text>
          </Pressable>
        ) : null}
      </View>
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
  panel: {
    alignItems: 'stretch',
    backgroundColor: '#071113',
    borderColor: 'rgba(34,211,238,0.34)',
    borderRadius: 28,
    borderWidth: 1,
    gap: 12,
    maxWidth: 430,
    padding: 20,
    width: '100%',
  },
  icon: {
    alignItems: 'center',
    alignSelf: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 28,
    height: 56,
    justifyContent: 'center',
    marginBottom: 2,
    width: 56,
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
  versionRow: {
    backgroundColor: 'rgba(2,10,11,0.72)',
    borderRadius: 16,
    gap: 5,
    padding: 12,
  },
  versionText: {
    color: '#A7B9BD',
    fontSize: 13,
    fontWeight: '700',
  },
  error: {
    color: '#FF9F9F',
    fontSize: 13,
    fontWeight: '800',
    textAlign: 'center',
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#22D3EE',
    borderRadius: 18,
    minHeight: 54,
    justifyContent: 'center',
    marginTop: 4,
  },
  primaryText: {
    color: '#031012',
    fontSize: 17,
    fontWeight: '900',
  },
  secondaryButton: {
    alignItems: 'center',
    minHeight: 44,
    justifyContent: 'center',
  },
  secondaryText: {
    color: '#A7B9BD',
    fontSize: 15,
    fontWeight: '800',
  },
});
