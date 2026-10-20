import React, { useRef } from 'react';
import { Animated, Pressable, StyleSheet, View } from 'react-native';
import { platformLabel } from '../copy';
import type { NearbyDevice } from '../native/types';
import { green, radii, spacing } from '../theme/tokens';
import { Icon } from './Icon';
import { IconBubble } from './IconBubble';
import { Text } from './Text';

interface DeviceRowProps {
  device: NearbyDevice;
  onPress: () => void;
  /** What tapping does, e.g. "Sends 3 files to Studio iMac". */
  actionHint: string;
  disabled?: boolean;
}

/** A nearby device as a row; pressing tints it mint. */
export function DeviceRow({
  device,
  onPress,
  actionHint,
  disabled,
}: DeviceRowProps) {
  const pressed = useRef(new Animated.Value(0)).current;
  const to = (v: number) =>
    Animated.timing(pressed, {
      toValue: v,
      duration: v ? 90 : 220,
      useNativeDriver: true,
    }).start();
  const status = device.trusted
    ? 'Paired · tap to send'
    : 'New · you’ll confirm a code';
  return (
    <Pressable
      onPress={onPress}
      onPressIn={() => to(1)}
      onPressOut={() => to(0)}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={`${device.name}, ${platformLabel(device.platform)}, ${
        device.trusted ? 'paired' : 'not paired'
      }`}
      accessibilityHint={actionHint}
      accessibilityState={{ disabled: !!disabled }}
      style={styles.row}
    >
      <Animated.View
        pointerEvents="none"
        style={[styles.pressed, { opacity: pressed }]}
      />
      <IconBubble
        name={device.platform === 'macos' ? 'laptop' : 'phone'}
        size={46}
      />
      <View style={styles.text}>
        <Text variant="headline" numberOfLines={1}>
          {device.name}
        </Text>
        <View style={styles.meta}>
          {device.trusted ? <View style={styles.dot} /> : null}
          <Text variant="footnote" tone="secondary" numberOfLines={1}>
            {status}
          </Text>
        </View>
      </View>
      <View style={styles.go}>
        <Icon name="send" size={18} color="#FFFFFF" strokeWidth={2} />
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.sm,
    borderRadius: radii.sm + 2,
    minHeight: 64,
  },
  pressed: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    borderRadius: radii.sm + 2,
    backgroundColor: 'rgba(20,154,91,0.10)',
  },
  text: { flex: 1, gap: 1 },
  meta: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  dot: { width: 7, height: 7, borderRadius: 4, backgroundColor: green },
  go: {
    width: 38,
    height: 38,
    borderRadius: 19,
    backgroundColor: '#0F1D16',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
