import React, { useEffect, useRef, useState } from 'react';
import { Animated, Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SoftShadow } from '../components/Frost';
import { Icon, IconName } from '../components/Icon';
import { Text } from '../components/Text';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import type { TabKey } from './NavigationContext';

export const TABS: { key: TabKey; label: string; icon: IconName }[] = [
  { key: 'nearby', label: 'Nearby', icon: 'radar' },
  { key: 'activity', label: 'Activity', icon: 'swap' },
  { key: 'devices', label: 'Devices', icon: 'devices' },
  { key: 'settings', label: 'Settings', icon: 'settings' },
];

const PAD = 10;
const LENS = 48;

interface TabBarProps {
  current: TabKey;
  onSelect: (tab: TabKey) => void;
  badges: Partial<Record<TabKey, number>>;
}

/** Floating white pill; a mint circle glides to the current tab with a spring. */
export function TabBar({ current, onSelect, badges }: TabBarProps) {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  const reduced = useReducedMotion();
  const [width, setWidth] = useState(0);
  const index = TABS.findIndex(tab => tab.key === current);
  const itemWidth = width > 0 ? (width - PAD * 2) / TABS.length : 0;
  const centre = (i: number) => PAD + itemWidth * (i + 0.5) - LENS / 2;
  const x = useRef(new Animated.Value(0)).current;
  const placed = useRef(false);

  useEffect(() => {
    if (itemWidth === 0) return;
    if (!placed.current || reduced) {
      placed.current = true;
      x.setValue(centre(index));
      return;
    }
    Animated.spring(x, {
      toValue: centre(index),
      useNativeDriver: true,
      speed: 16,
      bounciness: 6,
    }).start();
    // centre depends only on itemWidth and index
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [index, itemWidth, reduced, x]);

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
      <View>
        <SoftShadow offsetY={10} spread={10} color="rgba(24,84,52,0.12)" />
        <View
          accessibilityRole="tablist"
          style={styles.bar}
          onLayout={e => setWidth(e.nativeEvent.layout.width)}
        >
          {itemWidth > 0 ? (
            <Animated.View
              pointerEvents="none"
              style={[
                styles.lens,
                {
                  backgroundColor: t.accentSoft,
                  transform: [{ translateX: x }],
                },
              ]}
            />
          ) : null}
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
                <View style={styles.icon}>
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
    </View>
  );
}

const styles = StyleSheet.create({
  anchor: { position: 'absolute', left: 0, right: 0, bottom: 0 },
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 64,
    borderRadius: 26,
    paddingHorizontal: PAD,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.95)',
  },
  lens: {
    position: 'absolute',
    left: 0,
    top: (64 - 2 - LENS) / 2,
    width: LENS,
    height: LENS,
    borderRadius: LENS / 2,
  },
  item: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 56,
  },
  icon: {
    width: LENS,
    height: LENS,
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
