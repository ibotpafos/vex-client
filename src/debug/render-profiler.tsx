import React, { useEffect, useSyncExternalStore } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

type RenderMetric = {
  count: number;
  lastAt: number;
};

const storageKey = 'vex.renderProfiler';
const metrics = new Map<string, RenderMetric>();
const listeners = new Set<() => void>();
let snapshotVersion = 0;
let cachedSnapshot = '';
let notifyScheduled = false;

export function useRenderProfilerMark(name: string) {
  useEffect(() => {
    if (!isRenderProfilerEnabled()) return;
    recordRender(name);
  });
}

export function RenderProfilerOverlay() {
  const snapshot = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
  if (!isRenderProfilerEnabled()) {
    return null;
  }

  const rows = parseSnapshot(snapshot);
  if (!rows.length) {
    return null;
  }

  return (
    <View pointerEvents="box-none" style={styles.host}>
      <View style={styles.panel}>
        <View style={styles.header}>
          <Text style={styles.title}>renders</Text>
          <Pressable
            accessibilityLabel="Сбросить счетчики рендера"
            accessibilityRole="button"
            onPress={resetRenderProfiler}
            style={styles.resetButton}
          >
            <Text style={styles.resetText}>reset</Text>
          </Pressable>
        </View>
        {rows.map((row) => (
          <View key={row.name} style={styles.row}>
            <Text numberOfLines={1} style={styles.name}>{row.name}</Text>
            <Text style={styles.count}>{row.count}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}

function recordRender(name: string) {
  const current = metrics.get(name);
  metrics.set(name, {
    count: (current?.count ?? 0) + 1,
    lastAt: Date.now(),
  });
  scheduleNotify();
}

function resetRenderProfiler() {
  metrics.clear();
  snapshotVersion += 1;
  cachedSnapshot = '';
  emit();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function getSnapshot() {
  if (!cachedSnapshot) {
    cachedSnapshot = JSON.stringify({
      version: snapshotVersion,
      rows: Array.from(metrics.entries())
        .map(([name, metric]) => ({ name, ...metric }))
        .sort((left, right) => right.count - left.count || left.name.localeCompare(right.name)),
    });
  }
  return cachedSnapshot;
}

function parseSnapshot(snapshot: string): { count: number; name: string }[] {
  try {
    const parsed = JSON.parse(snapshot) as { rows?: { count: number; name: string }[] };
    return (parsed.rows ?? []).slice(0, 9);
  } catch {
    return [];
  }
}

function scheduleNotify() {
  if (notifyScheduled) return;
  notifyScheduled = true;
  const schedule = typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function'
    ? window.requestAnimationFrame
    : (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 1000);
  schedule(() => {
    notifyScheduled = false;
    snapshotVersion += 1;
    cachedSnapshot = '';
    emit();
  });
}

function emit() {
  listeners.forEach((listener) => listener());
}

function isRenderProfilerEnabled() {
  if (typeof __DEV__ !== 'undefined' && !__DEV__) {
    return false;
  }
  if (process.env.EXPO_PUBLIC_VEX_RENDER_PROFILER === '1') {
    return true;
  }
  if (typeof window === 'undefined') {
    return false;
  }
  try {
    const params = new URLSearchParams(window.location.search);
    if (params.get('perf') === '1') {
      window.localStorage.setItem(storageKey, '1');
      return true;
    }
    if (params.get('perf') === '0') {
      window.localStorage.removeItem(storageKey);
      return false;
    }
    return window.localStorage.getItem(storageKey) === '1';
  } catch {
    return false;
  }
}

const styles = StyleSheet.create({
  host: {
    bottom: 10,
    position: 'absolute',
    right: 10,
    zIndex: 9999,
  },
  panel: {
    backgroundColor: 'rgba(2,10,11,0.9)',
    borderColor: 'rgba(34,211,238,0.34)',
    borderRadius: 10,
    borderWidth: 1,
    minWidth: 168,
    padding: 8,
  },
  header: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  title: {
    color: '#22D3EE',
    fontSize: 10,
    fontWeight: '900',
  },
  resetButton: {
    paddingHorizontal: 4,
    paddingVertical: 2,
  },
  resetText: {
    color: '#A7B9BD',
    fontSize: 10,
    fontWeight: '800',
  },
  row: {
    alignItems: 'center',
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'space-between',
    minHeight: 16,
  },
  name: {
    color: '#EAF7F8',
    flex: 1,
    fontSize: 10,
    fontWeight: '800',
  },
  count: {
    color: '#B9FBFF',
    fontSize: 10,
    fontWeight: '900',
    minWidth: 22,
    textAlign: 'right',
  },
});
