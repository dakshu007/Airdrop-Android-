import React, { useEffect, useRef } from 'react';
import {
  Animated,
  Easing,
  Pressable,
  StyleProp,
  StyleSheet,
  View,
  ViewStyle,
} from 'react-native';
import { platformLabel } from '../copy';
import { useStill } from '../hooks/useStill';
import type { NearbyDevice } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { green, minTouch, spacing } from '../theme/tokens';
import { Frost, SoftShadow } from './Frost';
import { Icon, IconName } from './Icon';
import { IconBubble } from './IconBubble';
import { Text } from './Text';

/** A small glass pill with a coloured status dot, e.g. "● Receiving" or "● New device". */
export function StatusPill({
  label,
  dot = green,
  style,
}: {
  label: string;
  dot?: string;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <View style={[styles.pill, style]}>
      <Frost radius={999} />
      <View style={[styles.dot, { backgroundColor: dot }]} />
      <Text variant="subhead" style={styles.pillText} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

/** A 44dp round glass button with an icon (close, settings). */
export function RoundButton({
  icon,
  label,
  onPress,
}: {
  icon: IconName;
  label: string;
  onPress: () => void;
}) {
  const t = useTheme();
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={label}
      hitSlop={4}
      android_ripple={{ color: 'rgba(20,154,91,0.12)', borderless: true }}
      style={styles.round}
    >
      <Frost radius={22} />
      <Icon name={icon} size={20} color={t.textPrimary} strokeWidth={2} />
    </Pressable>
  );
}

/** Gentle up-and-down float, offset by `phase` so chips don't move in step. */
function useFloat(phase: number) {
  const reduced = useStill();
  const v = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (reduced) {
      v.setValue(0);
      return;
    }
    const duration = 2500 + phase * 350;
    const anim = Animated.loop(
      Animated.sequence([
        Animated.delay(phase * 400),
        Animated.timing(v, {
          toValue: 1,
          duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
        Animated.timing(v, {
          toValue: 0,
          duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
      ]),
    );
    anim.start();
    return () => anim.stop();
  }, [reduced, phase, v]);
  return v.interpolate({ inputRange: [0, 1], outputRange: [0, -7] });
}

interface FloatChipProps {
  /** Degrees of tilt, like a card dropped on a table. */
  tilt: number;
  phase?: number;
  style?: StyleProp<ViewStyle>;
  children: React.ReactNode;
}

/** A floating, slightly tilted glass chip (decorative). */
export function FloatChip({
  tilt,
  phase = 0,
  style,
  children,
}: FloatChipProps) {
  const y = useFloat(phase);
  return (
    <Animated.View
      style={[
        styles.chipShadow,
        { transform: [{ translateY: y }, { rotate: `${tilt}deg` }] },
        style,
      ]}
      importantForAccessibility="no-hide-descendants"
    >
      <SoftShadow offsetY={8} spread={8} color="rgba(24,84,52,0.13)" />
      <View style={styles.chip}>
        <Frost radius={16} />
        {children}
      </View>
    </Animated.View>
  );
}

interface DeviceChipProps {
  device: NearbyDevice;
  tilt: number;
  phase: number;
  disabled?: boolean;
  actionHint: string;
  onPress: () => void;
  /** Pressed in/out, so Drip can lean toward the chip. */
  onFocusChange?: (focused: boolean) => void;
  style?: StyleProp<ViewStyle>;
}

/** A nearby device as a floating glass chip; tapping it sends. */
export function DeviceChip({
  device,
  tilt,
  phase,
  disabled,
  actionHint,
  onPress,
  onFocusChange,
  style,
}: DeviceChipProps) {
  const t = useTheme();
  const y = useFloat(phase);
  const scale = useRef(new Animated.Value(1)).current;
  const press = (to: number) =>
    Animated.spring(scale, {
      toValue: to,
      useNativeDriver: true,
      speed: 30,
      bounciness: 8,
    }).start();
  return (
    <Animated.View
      style={[
        styles.chipShadow,
        { transform: [{ translateY: y }, { rotate: `${tilt}deg` }, { scale }] },
        style,
      ]}
    >
      <SoftShadow offsetY={10} spread={8} color="rgba(24,84,52,0.14)" />
      <Pressable
        onPress={onPress}
        onPressIn={() => {
          press(1.05);
          onFocusChange?.(true);
        }}
        onPressOut={() => {
          press(1);
          onFocusChange?.(false);
        }}
        onFocus={() => onFocusChange?.(true)}
        onBlur={() => onFocusChange?.(false)}
        disabled={disabled}
        accessibilityRole="button"
        accessibilityLabel={`${device.name}, ${platformLabel(
          device.platform,
        )}, ${device.trusted ? 'paired' : 'new device'}`}
        accessibilityHint={actionHint}
        accessibilityState={{ disabled: !!disabled }}
        android_ripple={{ color: 'rgba(20,154,91,0.12)', foreground: true }}
        style={styles.deviceChip}
      >
        <Frost radius={18} />
        <IconBubble
          name={device.platform === 'macos' ? 'laptop' : 'phone'}
          size={36}
        />
        <View style={styles.deviceText}>
          <Text variant="headline" style={styles.deviceName} numberOfLines={1}>
            {device.name}
          </Text>
          <View style={styles.deviceMeta}>
            {device.trusted ? (
              <View style={[styles.dot, styles.smallDot]} />
            ) : null}
            <Text variant="footnote" tone="secondary" numberOfLines={1}>
              {device.trusted ? 'Paired' : 'New · confirm a code'}
            </Text>
          </View>
        </View>
        <Icon name="send" size={16} color={t.link} strokeWidth={2} />
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'center',
    gap: spacing.xs,
    paddingHorizontal: 14,
    paddingVertical: 7,
    borderRadius: 999,
    overflow: 'hidden',
  },
  pillText: { color: '#2B3D33' },
  dot: { width: 7, height: 7, borderRadius: 4 },
  smallDot: { width: 6, height: 6, backgroundColor: green },
  round: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  chipShadow: {},
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: 16,
    overflow: 'hidden',
  },
  deviceChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    minHeight: minTouch + 8,
    paddingVertical: 10,
    paddingLeft: 10,
    paddingRight: 14,
    borderRadius: 18,
    overflow: 'hidden',
    maxWidth: 230,
  },
  deviceText: { flexShrink: 1, gap: 1 },
  deviceName: { fontSize: 14, lineHeight: 20 },
  deviceMeta: { flexDirection: 'row', alignItems: 'center', gap: 5 },
});
