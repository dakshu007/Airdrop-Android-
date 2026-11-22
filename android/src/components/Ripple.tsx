import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import { useStill } from '../hooks/useStill';
import { green } from '../theme/tokens';

interface RippleProps {
  /** Diameter of the widest ring. */
  size: number;
  color?: string;
  /** Rings in flight at once. */
  rings?: number;
  /** One ripple cycle. */
  duration?: number;
  /** Ripple once (a "sent" moment) instead of looping. */
  once?: boolean;
  children?: React.ReactNode;
}

/**
 * Soft rings spreading out from the centre, like a drop landing on water.
 * Purely decorative: hidden from screen readers. With Reduce Motion (or on a
 * hidden tab) it shows one faint static ring instead.
 */
export function Ripple({
  size,
  color = green,
  rings = 2,
  duration = 2400,
  once,
  children,
}: RippleProps) {
  const still = useStill();
  const values = useRef(
    Array.from({ length: rings }, () => new Animated.Value(0)),
  ).current;

  useEffect(() => {
    if (still) {
      values.forEach(v => v.setValue(0.55));
      return;
    }
    const waves = values.map((v, i) =>
      Animated.sequence([
        Animated.delay((duration / values.length) * i),
        Animated.timing(v, {
          toValue: 1,
          duration,
          easing: Easing.out(Easing.cubic),
          useNativeDriver: true,
        }),
      ]),
    );
    values.forEach(v => v.setValue(0));
    const anim = once
      ? Animated.parallel(waves)
      : Animated.loop(Animated.parallel(waves));
    anim.start();
    return () => anim.stop();
  }, [still, once, duration, values]);

  return (
    <View
      style={[styles.box, { width: size, height: size }]}
      importantForAccessibility="no-hide-descendants"
      accessibilityElementsHidden
      pointerEvents="none"
    >
      {(still ? values.slice(0, 1) : values).map((v, i) => (
        <Animated.View
          key={i}
          style={[
            styles.ring,
            {
              width: size,
              height: size,
              borderRadius: size / 2,
              borderColor: color,
              opacity: v.interpolate({
                inputRange: [0, 0.15, 1],
                outputRange: [0, 0.5, 0],
              }),
              transform: [
                {
                  scale: v.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0.35, 1],
                  }),
                },
              ],
            },
          ]}
        />
      ))}
      {children ? <View style={styles.center}>{children}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { alignItems: 'center', justifyContent: 'center' },
  ring: { position: 'absolute', borderWidth: 1.5 },
  center: { alignItems: 'center', justifyContent: 'center' },
});
