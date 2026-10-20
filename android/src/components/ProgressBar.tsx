import React, { useEffect, useRef, useState } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { useTheme } from '../theme/ThemeProvider';

interface ProgressBarProps {
  /** 0…1 */
  value: number;
  color?: string;
  accessibilityLabel: string;
}

/** Thin capsule progress bar; animates with a spring unless reduced motion is on. */
export function ProgressBar({
  value,
  color,
  accessibilityLabel,
}: ProgressBarProps) {
  const t = useTheme();
  const reduced = useReducedMotion();
  const clamped = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
  const [width, setWidth] = useState(0);
  const anim = useRef(new Animated.Value(clamped)).current;

  useEffect(() => {
    if (reduced) {
      anim.setValue(clamped);
      return;
    }
    Animated.spring(anim, {
      toValue: clamped,
      useNativeDriver: true,
      speed: 14,
      bounciness: 0,
    }).start();
  }, [anim, clamped, reduced]);

  const translateX = anim.interpolate({
    inputRange: [0, 1],
    outputRange: [-width, 0],
  });
  const percent = Math.round(clamped * 100);
  // Hidden until measured, so the bar never flashes full width.
  const fillOpacity = width > 0 ? 1 : 0;

  return (
    <View
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={{
        min: 0,
        max: 100,
        now: percent,
        text: `${percent} percent`,
      }}
      onLayout={e => setWidth(e.nativeEvent.layout.width)}
      style={[styles.track, { backgroundColor: t.track }]}
    >
      <Animated.View
        style={[
          styles.fill,
          {
            backgroundColor: color ?? t.accent,
            opacity: fillOpacity,
            transform: [{ translateX }],
          },
        ]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  track: { height: 8, borderRadius: 4, overflow: 'hidden' },
  fill: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    borderRadius: 4,
  },
});
