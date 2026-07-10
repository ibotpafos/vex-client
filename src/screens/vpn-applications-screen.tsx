import { router } from 'expo-router';
import { Check, ChevronLeft, Search } from 'lucide-react-native';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Image,
  Platform,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { playErrorHaptic, playSelectionHaptic } from '@/native/haptics';
import { getInstalledVpnApplications, type InstalledVpnApplication } from '@/native/vexVpn';
import {
  getVpnApplicationSelection,
  setSelectedVpnApplications,
  setVpnApplicationRoutingMode,
  type VpnApplicationRoutingMode,
} from '@/settings/vpnPreferences';
import { useToast } from '@/ui/toast';
import { vexColors, VexPressable, VexScreen, vexSharedStyles } from '@/ui/vex-ui';

export default function VpnApplicationsScreen() {
  const { showToast } = useToast();
  const [applications, setApplications] = useState<InstalledVpnApplication[]>([]);
  const [selectedPackages, setSelectedPackages] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<VpnApplicationRoutingMode>('all');
  const [query, setQuery] = useState('');
  const [loading, setLoading] = useState(true);
  const saveQueue = useRef<Promise<unknown>>(Promise.resolve());

  const queueSave = useCallback((operation: () => Promise<unknown>) => {
    saveQueue.current = saveQueue.current
      .then(operation)
      .catch(() => {
        playErrorHaptic();
        showToast({ duration: 'long', message: 'Не удалось сохранить выбор приложений.', variant: 'error' });
      });
  }, [showToast]);

  useEffect(() => {
    let mounted = true;
    if (Platform.OS !== 'android') {
      setLoading(false);
      return () => undefined;
    }
    Promise.all([getInstalledVpnApplications(), getVpnApplicationSelection()])
      .then(([installed, selection]) => {
        if (!mounted) return;
        const installedPackages = new Set(installed.map((item) => item.packageName));
        const selected = selection.packageNames.filter((packageName) => installedPackages.has(packageName));
        setApplications(installed);
        setSelectedPackages(new Set(selected));
        setMode(selection.mode === 'selected' && selected.length > 0 ? 'selected' : 'all');
        if (selected.length !== selection.packageNames.length) {
          queueSave(() => setSelectedVpnApplications(selected));
        }
      })
      .catch(() => {
        if (!mounted) return;
        playErrorHaptic();
        showToast({ duration: 'long', message: 'Не удалось загрузить список приложений.', variant: 'error' });
      })
      .finally(() => {
        if (mounted) setLoading(false);
      });
    return () => {
      mounted = false;
    };
  }, [queueSave, showToast]);

  const filteredApplications = useMemo(() => {
    const normalizedQuery = query.trim().toLocaleLowerCase();
    if (!normalizedQuery) return applications;
    return applications.filter((application) =>
      application.label.toLocaleLowerCase().includes(normalizedQuery) ||
      application.packageName.toLocaleLowerCase().includes(normalizedQuery));
  }, [applications, query]);

  const selectMode = useCallback((nextMode: VpnApplicationRoutingMode) => {
    if (nextMode === 'selected' && selectedPackages.size === 0) {
      showToast({ message: 'Сначала выберите хотя бы одно приложение.', variant: 'warning' });
      return;
    }
    playSelectionHaptic();
    setMode(nextMode);
    queueSave(() => setVpnApplicationRoutingMode(nextMode));
  }, [queueSave, selectedPackages.size, showToast]);

  const toggleApplication = useCallback((packageName: string) => {
    playSelectionHaptic();
    setSelectedPackages((current) => {
      const next = new Set(current);
      if (next.has(packageName)) {
        next.delete(packageName);
      } else {
        next.add(packageName);
      }
      const packageNames = [...next];
      queueSave(() => setSelectedVpnApplications(packageNames));
      const nextMode: VpnApplicationRoutingMode = packageNames.length > 0 ? 'selected' : 'all';
      setMode(nextMode);
      queueSave(() => setVpnApplicationRoutingMode(nextMode));
      return next;
    });
  }, [queueSave]);

  const renderApplication = useCallback(({ item }: { item: InstalledVpnApplication }) => {
    const selected = selectedPackages.has(item.packageName);
    return (
      <VexPressable
        accessibilityLabel={`${item.label}, ${selected ? 'использует VPN' : 'не использует VPN'}`}
        accessibilityRole="checkbox"
        accessibilityState={{ checked: selected }}
        onPress={() => toggleApplication(item.packageName)}
        style={[styles.applicationRow, selected && styles.applicationRowSelected]}
        hoverStyle={{ backgroundColor: 'rgba(34,211,238,0.10)' }}
        title={selected ? `Исключить ${item.label} из VPN` : `Направить ${item.label} через VPN`}
      >
        <Image source={{ uri: item.iconDataUri }} style={styles.applicationIcon} />
        <View style={styles.applicationCopy}>
          <Text numberOfLines={1} style={styles.applicationLabel}>{item.label}</Text>
          <Text numberOfLines={1} style={styles.packageName}>{item.packageName}</Text>
        </View>
        <View style={[styles.checkbox, selected && styles.checkboxSelected]}>
          {selected ? <Check color="#031012" size={18} strokeWidth={3} /> : null}
        </View>
      </VexPressable>
    );
  }, [selectedPackages, toggleApplication]);

  return (
    <VexScreen>
      <View style={vexSharedStyles.topBar}>
        <VexPressable
          accessibilityLabel="Назад"
          onPress={() => router.back()}
          style={vexSharedStyles.iconButton}
          hoverStyle={{ opacity: 0.72 }}
          title="Назад"
        >
          <ChevronLeft color="#EAF7F8" size={26} strokeWidth={2.4} />
        </VexPressable>
        <Text style={vexSharedStyles.title}>Приложения</Text>
        <View style={vexSharedStyles.iconButton} />
      </View>

      <FlatList
        contentContainerStyle={styles.listContent}
        data={filteredApplications}
        initialNumToRender={14}
        keyExtractor={(item) => item.packageName}
        keyboardShouldPersistTaps="handled"
        ListEmptyComponent={loading ? (
          <View style={styles.emptyState}>
            <ActivityIndicator color={vexColors.accent} size="large" />
            <Text style={styles.emptyText}>Загружаем приложения…</Text>
          </View>
        ) : (
          <View style={styles.emptyState}>
            <Text style={styles.emptyTitle}>Ничего не найдено</Text>
            <Text style={styles.emptyText}>Измените поисковый запрос.</Text>
          </View>
        )}
        ListHeaderComponent={(
          <View style={styles.headerContent}>
            <Text style={styles.description}>
              Выберите приложения, которые должны использовать VPN. Изменения применятся при следующем подключении.
            </Text>
            <View accessibilityLabel="Режим маршрутизации приложений" style={styles.modeSelector}>
              <ModeButton active={mode === 'all'} label="Все приложения" onPress={() => selectMode('all')} />
              <ModeButton active={mode === 'selected'} label={`Выбранные (${selectedPackages.size})`} onPress={() => selectMode('selected')} />
            </View>
            <View style={styles.searchField}>
              <Search color={vexColors.muted} size={19} strokeWidth={2.4} />
              <TextInput
                accessibilityLabel="Поиск приложений"
                autoCapitalize="none"
                autoCorrect={false}
                onChangeText={setQuery}
                placeholder="Поиск"
                placeholderTextColor="rgba(167,185,189,0.62)"
                style={styles.searchInput}
                value={query}
              />
            </View>
          </View>
        )}
        maxToRenderPerBatch={12}
        renderItem={renderApplication}
        showsVerticalScrollIndicator={false}
        style={styles.list}
        windowSize={7}
      />
    </VexScreen>
  );
}

function ModeButton({ active, label, onPress }: { active: boolean; label: string; onPress: () => void }) {
  return (
    <VexPressable
      accessibilityRole="button"
      accessibilityState={{ selected: active }}
      onPress={onPress}
      style={[styles.modeButton, active && styles.modeButtonActive]}
      hoverStyle={{ opacity: 0.86 }}
      title={label}
    >
      <Text style={[styles.modeButtonText, active && styles.modeButtonTextActive]}>{label}</Text>
    </VexPressable>
  );
}

const styles = StyleSheet.create({
  list: { flex: 1 },
  listContent: { gap: 6, paddingBottom: 20 },
  headerContent: { gap: 10, paddingBottom: 8 },
  description: { color: vexColors.muted, fontSize: 13, lineHeight: 18 },
  modeSelector: {
    backgroundColor: vexColors.field,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 4,
    padding: 4,
  },
  modeButton: { alignItems: 'center', borderRadius: 10, flex: 1, justifyContent: 'center', minHeight: 42, paddingHorizontal: 8 },
  modeButtonActive: { backgroundColor: vexColors.accent },
  modeButtonText: { color: vexColors.muted, fontSize: 12, fontWeight: '900' },
  modeButtonTextActive: { color: '#031012' },
  searchField: {
    alignItems: 'center',
    backgroundColor: vexColors.field,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 8,
    minHeight: 46,
    paddingHorizontal: 13,
  },
  searchInput: { color: vexColors.text, flex: 1, fontSize: 15, minHeight: 44, paddingVertical: 0 },
  applicationRow: {
    alignItems: 'center',
    backgroundColor: vexColors.card,
    borderColor: vexColors.line,
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    gap: 11,
    minHeight: 66,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  applicationRowSelected: { backgroundColor: 'rgba(34,211,238,0.08)', borderColor: 'rgba(34,211,238,0.42)' },
  applicationIcon: { borderRadius: 11, height: 44, width: 44 },
  applicationCopy: { flex: 1, minWidth: 0 },
  applicationLabel: { color: vexColors.textSoft, fontSize: 15, fontWeight: '900' },
  packageName: { color: vexColors.muted, fontSize: 10, marginTop: 3 },
  checkbox: {
    alignItems: 'center',
    borderColor: 'rgba(167,185,189,0.48)',
    borderRadius: 8,
    borderWidth: 2,
    height: 28,
    justifyContent: 'center',
    width: 28,
  },
  checkboxSelected: { backgroundColor: vexColors.accent, borderColor: vexColors.accent },
  emptyState: { alignItems: 'center', gap: 10, paddingHorizontal: 24, paddingVertical: 48 },
  emptyTitle: { color: vexColors.textSoft, fontSize: 17, fontWeight: '900' },
  emptyText: { color: vexColors.muted, fontSize: 13, textAlign: 'center' },
});
