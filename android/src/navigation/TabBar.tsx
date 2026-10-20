import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Frost } from '../components/Frost';
import { Icon, IconName } from '../components/Icon';
import { Text } from '../components/Text';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import type { TabKey } from './NavigationContext';

export const TABS: { key: TabKey; label: string; icon: IconName }[] = [
  { key: 'nearby', label: 'Nearby', icon: 'radar' },
  { key: 'activity', label: 'Activity', icon: 'swap' },
  { key: 'devices', label: 'Devices', icon: 'devices' },
  { key: 'settings', label: 'Settings', icon: 'settings' },
];

interface TabBarProps {
  current: TabKey;
  onSelect: (tab: TabKey) => void;
  badges: Partial<Record<TabKey, number>>;
}

/** Floating white glass pill; the current tab sits in a mint circle with its name beneath. */
export function TabBar({ current, onSelect, badges }: TabBarProps) {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  return (
    <View
      pointerEvents="box-none"
      style={[
        styles.anchor,
        {
          paddingBottom: Math.max(insets.bottom, spacing.sm) + spacing.xs,
          paddingLeft: insets.left + spacing.xl,
          paddingRight: insets.right + spacing.xl,
        },
      ]}
    >
      <View accessibilityRole="tablist" style={styles.bar}>
        <Frost radius={26} tint="rgba(255,255,255,0.96)" />
        {TABS.map(tab => {
          const selected = tab.key === current;
          const badge = badges[tab.key] ?? 0;
          return (
            <Pressable
              key={tab.key}
              onPress={() => onSelect(tab.key)}
              accessibilityRole="tab"
              accessibilityLabel={
                badge > 0 ? `${tab.label}, ${badge} active` : tab.label
              }
              accessibilityState={{ selected }}
              style={styles.item}
            >
              <View
                style={[
                  styles.lens,
                  selected && { backgroundColor: t.accentSoft },
                ]}
              >
                <Icon
                  name={tab.icon}
                  size={22}
                  color={selected ? t.textPrimary : t.textTertiary}
                  strokeWidth={selected ? 2 : 1.8}
                />
                {badge > 0 ? (
                  <View style={styles.badge}>
                    <Text
                      variant="caption"
                      tone="onAccent"
                      maxFontSizeMultiplier={1.3}
                      style={styles.badgeText}
                    >
                      {badge > 9 ? '9+' : badge}
                    </Text>
                  </View>
                ) : null}
              </View>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  anchor: { position: 'absolute', left: 0, right: 0, bottom: 0 },
  bar: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    alignItems: 'center',
    height: 64,
    borderRadius: 26,
    paddingHorizontal: 10,
    overflow: 'hidden',
    shadowColor: '#185434',
    shadowOpacity: 0.1,
    shadowRadius: 20,
    shadowOffset: { width: 0, height: 10 },
  },
  item: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 56,
  },
  lens: {
    width: 48,
    height: 48,
    borderRadius: 24,
    alignItems: 'center',
    justifyContent: 'center',
  },
  badge: {
    position: 'absolute',
    top: 4,
    right: 2,
    minWidth: 18,
    height: 18,
    paddingHorizontal: 4,
    borderRadius: 9,
    backgroundColor: '#149A5B',
    borderWidth: 1.5,
    borderColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
  },
  badgeText: { fontSize: 10.5, lineHeight: 13 },
});
