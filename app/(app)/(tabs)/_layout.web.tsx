import { Slot, usePathname, useRouter } from 'expo-router';
import React, { useMemo } from 'react';
import { StyleSheet, Text, View, Platform } from 'react-native';
import { Home, User, MessageCircle } from 'lucide-react-native';
import { VexPressable } from '@/ui/vex-ui';

export default function WebTabsLayout() {
  const pathname = usePathname();
  const router = useRouter();

  // Determine active tab based on pathname
  const activeTab = useMemo(() => {
    if (pathname.includes('/account')) {
      return 'account';
    }
    if (pathname.includes('/support')) {
      return 'support';
    }
    return 'index';
  }, [pathname]);

  const handlePress = (tabName: string) => {
    if (tabName === 'support') {
      // Support opens as a modal stack screen
      router.push('/(app)/support-chat');
    } else if (tabName === 'account') {
      router.push('/(app)/(tabs)/account');
    } else {
      router.push('/(app)/(tabs)/');
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.content}>
        <Slot />
      </View>

      <View style={styles.tabBarContainer}>
        <View style={styles.tabBar}>
          {/* Home Tab */}
          <VexPressable
            onPress={() => handlePress('index')}
            style={[styles.tabItem, activeTab === 'index' && styles.tabItemActive]}
            hoverStyle={activeTab === 'index' ? null : styles.tabItemHover}
            title="Главная"
          >
            <Home
              size={20}
              color={activeTab === 'index' ? '#031012' : 'rgba(167,185,189,0.8)'}
              strokeWidth={activeTab === 'index' ? 2.5 : 2}
            />
            <Text style={[styles.tabLabel, activeTab === 'index' && styles.tabLabelActive]}>
              Главная
            </Text>
          </VexPressable>

          {/* Account Tab */}
          <VexPressable
            onPress={() => handlePress('account')}
            style={[styles.tabItem, activeTab === 'account' && styles.tabItemActive]}
            hoverStyle={activeTab === 'account' ? null : styles.tabItemHover}
            title="Аккаунт"
          >
            <User
              size={20}
              color={activeTab === 'account' ? '#031012' : 'rgba(167,185,189,0.8)'}
              strokeWidth={activeTab === 'account' ? 2.5 : 2}
            />
            <Text style={[styles.tabLabel, activeTab === 'account' && styles.tabLabelActive]}>
              Аккаунт
            </Text>
          </VexPressable>

          {/* Support Tab */}
          <VexPressable
            onPress={() => handlePress('support')}
            style={[styles.tabItem, activeTab === 'support' && styles.tabItemActive]}
            hoverStyle={activeTab === 'support' ? null : styles.tabItemHover}
            title="Поддержка"
          >
            <MessageCircle
              size={20}
              color={activeTab === 'support' ? '#031012' : 'rgba(167,185,189,0.8)'}
              strokeWidth={activeTab === 'support' ? 2.5 : 2}
            />
            <Text style={[styles.tabLabel, activeTab === 'support' && styles.tabLabelActive]}>
              Поддержка
            </Text>
          </VexPressable>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#020A0B',
  },
  content: {
    flex: 1,
    paddingBottom: 82,
  },
  tabBarContainer: {
    position: 'absolute',
    bottom: 24,
    left: 0,
    right: 0,
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 100,
    paddingHorizontal: 16,
    pointerEvents: 'box-none',
  },
  tabBar: {
    flexDirection: 'row',
    backgroundColor: 'rgba(7, 17, 19, 0.85)',
    borderRadius: 30,
    paddingHorizontal: 8,
    paddingVertical: 6,
    borderWidth: 1,
    borderColor: 'rgba(34, 211, 238, 0.2)',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 8 },
    shadowOpacity: 0.4,
    shadowRadius: 16,
    elevation: 8,
    maxWidth: 420,
    width: '100%',
    justifyContent: 'space-between',
    alignItems: 'center',
    // Web-only glassmorphism blur
    ...Platform.select({
      web: {
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
      } as any,
    }),
  },
  tabItem: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 10,
    paddingHorizontal: 12,
    borderRadius: 24,
    gap: 8,
    marginHorizontal: 4,
  },
  tabItemActive: {
    backgroundColor: '#22D3EE',
  },
  tabItemHover: {
    backgroundColor: 'rgba(34, 211, 238, 0.08)',
  },
  tabLabel: {
    fontSize: 12,
    fontWeight: '700',
    color: 'rgba(167, 185, 189, 0.8)',
  },
  tabLabelActive: {
    color: '#031012',
    fontWeight: '800',
  },
});
