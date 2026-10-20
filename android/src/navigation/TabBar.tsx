import React, { useEffect, useRef, useState } from 'react';
import { Animated, Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Icon, IconName } from '../components/Icon';
import { Specular } from '../components/Specular';
import { Text } from '../components/Text';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, radii, spacing } from '../theme/tokens';
import type { TabKey } from './NavigationContext';

export const TABS: { key: TabKey; label: string; icon: IconName }[] = [
  { key: 'nearby', label: 'Nearby', icon: 'send' },
  { key: 'activity', label: 'Activity', icon: 'inbox' },
  { key: 'devices', label: 'Devices', icon: 'devices' },
  { key: 'settings', label: 'Settings', icon: 'settings' },
];

interface TabBarProps {
  current: TabKey;
  onSelect: (tab: TabKey) => void;
  badges: Partial<Record<TabKey, number>>;
}

/** Floating glass pill with a sliding selection lens. */
export function TabBar({ current, onSelect, badges }: TabBarProps) {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  const reduced = useReducedMotion();
  const [width, setWidth] = useState(0);
  const index = TABS.findIndex(tab => tab.key === current);
  const position = useRef(new Animated.Value(index)).current;
  const itemWidth = width / TABS.length;

  useEffect(() => {
    if (reduced) {
      position.setValue(index);
    } else {
      Animated.spring(position, {
        toValue: index,
        useNativeDriver: true,
        speed: 18,
        bounciness: 7,
      }).start();
    }
  }, [index, position, reduced]);

  const accent = t.scheme === 'dark' ? '#9DB8FF' : t.accent;

  return (
    <View
      pointerEvents="box-none"
      style={[
        styles.anchor,
        {
          paddingBottom: Math.max(insets.bottom, spacing.sm) + spacing.xs,
          paddingLeft: insets.left + spacing.lg,
          paddingRight: insets.right + spacing.lg,
        },
      ]}
    >
      <View
        accessibilityRole="tablist"
        onLayout={e => setWidth(e.nativeEvent.layout.width - 14)}
        style={[
          styles.bar,
          { backgroundColor: t.glassFillStrong, borderColor: t.glassBorder },
        ]}
      >
        <Specular color={t.specular} />
        {width > 0 ? (
          <Animated.View
            style={[
              styles.lens,
              {
                width: itemWidth,
                backgroundColor: t.accentSoft,
                transform: [
                  {
                    translateX: position.interpolate({
                      inputRange: [0, TABS.length - 1],
                      outputRange: [0, itemWidth * (TABS.length - 1)],
                    }),
                  },
                ],
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
              <View>
                <Icon
                  name={tab.icon}
                  size={22}
                  color={selected ? accent : t.textSecondary}
                />
                {badge > 0 ? (
                  <View
                    style={[
                      styles.badge,
                      {
                        backgroundColor: t.accent,
                        borderColor: t.glassFillStrong,
                      },
                    ]}
                  >
                    <Text
                      variant="caption"
                      tone="onAccent"
                      maxFontSizeMultiplier={1.3}
                    >
                      {badge > 9 ? '9+' : badge}
                    </Text>
                  </View>
                ) : null}
              </View>
              <Text
                variant="caption"
                tone={selected ? 'accent' : 'secondary'}
                numberOfLines={1}
                maxFontSizeMultiplier={1.4}
              >
                {tab.label}
              </Text>
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
    borderRadius: radii.lg,
    borderWidth: 1,
    padding: 6,
    overflow: 'hidden',
  },
  lens: {
    position: 'absolute',
    top: 6,
    bottom: 6,
    left: 6,
    borderRadius: radii.md,
  },
  item: {
    flex: 1,
    minHeight: minTouch + 8,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 2,
    paddingVertical: spacing.xxs,
  },
  badge: {
    position: 'absolute',
    top: -6,
    right: -12,
    minWidth: 18,
    paddingHorizontal: 4,
    borderRadius: 9,
    borderWidth: 1.5,
    alignItems: 'center',
  },
});
