import React, { useEffect, useRef } from 'react';
import { Animated, Easing, Pressable, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';
import type { NearbyDevice } from '../native/types';
import { Frost } from './Frost';
import { Icon } from './Icon';
import { Text } from './Text';

const SIZE = 236;
const CORE = 78;
const ORBIT = 96;
const BUBBLE = 54;
const PULSES = 3;
const PERIOD = 3400;
/** Where devices sit on the orbit (degrees, 0 = right, clockwise). */
const SLOTS = [-28, 208, 34, 146, -90];
const HEIGHT = SIZE + 18;

/**
 * Discovery radar: soft pulses ripple out from this phone while scanning and
 * nearby devices appear on the orbit as glass bubbles you can tap. With reduced
 * motion the pulses are static rings.
 */
export function Radar({
  scanning,
  devices,
  onSelect,
}: {
  scanning: boolean;
  devices: NearbyDevice[];
  onSelect: (device: NearbyDevice) => void;
}) {
  const reduced = useReducedMotion();
  const animate = scanning && !reduced;
  const pulses = useRef(Array.from({ length: PULSES }, () => new Animated.Value(0))).current;
  const appear = useRef(new Map<string, Animated.Value>()).current;

  useEffect(() => {
    if (!animate) {
      pulses.forEach(v => {
        v.stopAnimation();
        v.setValue(0);
      });
      return;
    }
    const loops = pulses.map((v, i) =>
      Animated.loop(
        Animated.sequence([
          Animated.delay((PERIOD / PULSES) * i),
          Animated.timing(v, { toValue: 1, duration: PERIOD, easing: Easing.out(Easing.cubic), useNativeDriver: true }),
          Animated.timing(v, { toValue: 0, duration: 0, useNativeDriver: true }),
        ]),
      ),
    );
    loops.forEach(l => l.start());
    return () => loops.forEach(l => l.stop());
  }, [animate, pulses]);

  const shown = devices.slice(0, SLOTS.length);
  shown.forEach(d => {
    if (!appear.has(d.deviceId)) {
      const v = new Animated.Value(reduced ? 1 : 0);
      appear.set(d.deviceId, v);
      if (!reduced) {
        Animated.spring(v, { toValue: 1, useNativeDriver: true, speed: 10, bounciness: 10 }).start();
      }
    }
  });

  return (
    <View style={styles.wrap}>
      {/* Static guide rings */}
      {[1, 0.72].map(k => (
        <View
          key={k}
          pointerEvents="none"
          style={[
            styles.ring,
            { width: SIZE * k, height: SIZE * k, borderRadius: (SIZE * k) / 2, opacity: k === 1 ? 0.16 : 0.24 },
          ]}
        />
      ))}
      {pulses.map((v, i) => (
        <Animated.View
          key={i}
          pointerEvents="none"
          style={[
            styles.pulse,
            animate
              ? {
                  opacity: v.interpolate({ inputRange: [0, 0.2, 1], outputRange: [0, 0.55, 0] }),
                  transform: [{ scale: v.interpolate({ inputRange: [0, 1], outputRange: [0.32, 1] }) }],
                }
              : { opacity: 0 },
          ]}
        />
      ))}
      <View
        style={styles.core}
        accessible
        accessibilityRole="image"
        accessibilityLabel={scanning ? 'This phone, looking for nearby devices' : 'This phone'}
      >
        <Frost radius={CORE / 2} tint="rgba(255,255,255,0.2)" />
        <Icon name="phone" size={32} color="#FFFFFF" />
      </View>
      {shown.map((d, i) => {
        const a = (SLOTS[i] * Math.PI) / 180;
        const x = SIZE / 2 + ORBIT * Math.cos(a) - BUBBLE / 2;
        const y = HEIGHT / 2 + ORBIT * Math.sin(a) - BUBBLE / 2;
        const v = appear.get(d.deviceId)!;
        return (
          <Animated.View
            key={d.deviceId}
            style={[
              styles.device,
              { left: x - 18, top: y, opacity: v, transform: [{ scale: v.interpolate({ inputRange: [0, 1], outputRange: [0.4, 1] }) }] },
            ]}
          >
            <Pressable
              onPress={() => onSelect(d)}
              accessibilityRole="button"
              accessibilityLabel={`Send to ${d.name}`}
              style={styles.devicePress}
            >
              <View style={styles.bubble}>
                <Frost radius={BUBBLE / 2} tint="rgba(255,255,255,0.2)" />
                <Icon name={d.platform === 'macos' ? 'laptop' : 'phone'} size={24} color="#FFFFFF" />
                {d.trusted ? <View style={styles.paired} /> : null}
              </View>
              <Text variant="caption" numberOfLines={1} center style={styles.label}>
                {shortName(d.name)}
              </Text>
            </Pressable>
          </Animated.View>
        );
      })}
    </View>
  );
}

function shortName(name: string): string {
  const clean = name.replace(/[’']s\b/, '');
  return clean.length > 14 ? `${clean.slice(0, 13)}…` : clean;
}

const styles = StyleSheet.create({
  wrap: {
    width: SIZE,
    height: HEIGHT,
    alignItems: 'center',
    justifyContent: 'center',
    alignSelf: 'center',
  },
  ring: {
    position: 'absolute',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.9)',
  },
  pulse: {
    position: 'absolute',
    width: SIZE,
    height: SIZE,
    borderRadius: SIZE / 2,
    borderWidth: 1.5,
    borderColor: '#FFFFFF',
    backgroundColor: 'rgba(255,255,255,0.05)',
  },
  core: {
    width: CORE,
    height: CORE,
    borderRadius: CORE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  device: { position: 'absolute', width: BUBBLE + 36, alignItems: 'center' },
  devicePress: { alignItems: 'center', gap: 4 },
  bubble: {
    width: BUBBLE,
    height: BUBBLE,
    borderRadius: BUBBLE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  paired: {
    position: 'absolute',
    right: 9,
    top: 9,
    width: 9,
    height: 9,
    borderRadius: 5,
    backgroundColor: '#6EEBA0',
    borderWidth: 1.5,
    borderColor: 'rgba(255,255,255,0.9)',
  },
  label: { maxWidth: BUBBLE + 36 },
});
