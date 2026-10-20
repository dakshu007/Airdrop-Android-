import React, { useRef } from 'react';
import {
  AccessibilityRole,
  AccessibilityState,
  Animated,
  Pressable,
  StyleProp,
  StyleSheet,
  View,
  ViewStyle,
} from 'react-native';
import { radii, spacing } from '../theme/tokens';
import { Frost } from './Frost';

interface GlassCardProps {
  children: React.ReactNode;
  style?: StyleProp<ViewStyle>;
  contentStyle?: StyleProp<ViewStyle>;
  radius?: number;
  padding?: number;
  strong?: boolean;
  tint?: string;
  onPress?: () => void;
  disabled?: boolean;
  accessibilityLabel?: string;
  accessibilityHint?: string;
  accessibilityRole?: AccessibilityRole;
  accessibilityState?: AccessibilityState;
  testID?: string;
}

/**
 * White glass card: translucent fill, bright rim and a top specular sheen.
 * Pressable cards compress slightly with a spring.
 */
export function GlassCard({
  children,
  style,
  contentStyle,
  radius = radii.md,
  padding = spacing.md,
  strong,
  tint,
  onPress,
  disabled,
  accessibilityLabel,
  accessibilityHint,
  accessibilityRole,
  accessibilityState,
  testID,
}: GlassCardProps) {
  const scale = useRef(new Animated.Value(1)).current;

  const surface = (
    <View style={[styles.surface, { borderRadius: radius }]}>
      <Frost
        radius={radius}
        tint={strong ? 'rgba(255,255,255,0.86)' : undefined}
      />
      {tint ? (
        <View
          pointerEvents="none"
          style={[StyleSheet.absoluteFill, { backgroundColor: tint }]}
        />
      ) : null}
      <View style={[{ padding }, contentStyle]}>{children}</View>
    </View>
  );

  if (!onPress) {
    return (
      <View
        style={[styles.shadowWrap, { borderRadius: radius }, style]}
        accessible={accessibilityLabel !== undefined}
        accessibilityLabel={accessibilityLabel}
        accessibilityRole={accessibilityRole}
        testID={testID}
      >
        {surface}
      </View>
    );
  }

  const springTo = (value: number) =>
    Animated.spring(scale, {
      toValue: value,
      useNativeDriver: true,
      speed: 40,
      bounciness: 6,
    }).start();

  return (
    <Animated.View
      style={[
        styles.shadowWrap,
        { borderRadius: radius, transform: [{ scale }] },
        style,
      ]}
    >
      <Pressable
        onPress={onPress}
        disabled={disabled}
        onPressIn={() => springTo(0.97)}
        onPressOut={() => springTo(1)}
        accessibilityRole={accessibilityRole ?? 'button'}
        accessibilityLabel={accessibilityLabel}
        accessibilityHint={accessibilityHint}
        accessibilityState={{ disabled: !!disabled, ...accessibilityState }}
        android_ripple={{
          color: 'rgba(20,154,91,0.10)',
          borderless: false,
          foreground: true,
        }}
        style={[styles.pressable, { borderRadius: radius }]}
        testID={testID}
      >
        {surface}
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  shadowWrap: { boxShadow: '0px 10px 24px rgba(24,84,52,0.08)' },
  pressable: { overflow: 'hidden', minHeight: 48 },
  surface: {
    overflow: 'hidden',
  },
});
