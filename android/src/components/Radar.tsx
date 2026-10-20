import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { useTheme } from '../theme/ThemeProvider';
import { Icon } from './Icon';
import { Specular } from './Specular';

const SIZE = 168;
const RINGS = 3;
const PERIOD = 3600;

/**
 * Discovery indicator: rings ripple out from this phone while scanning.
 * With reduced motion (or when not scanning) the rings are drawn static.
 */
export function Radar({ scanning }: { scanning: boolean }) {
  const t = useTheme();
  const reduced = useReducedMotion();
  const animate = scanning && !reduced;
  const values = useRef(
    Array.from({ length: RINGS }, () => new Animated.Value(0)),
  ).current;

  useEffect(() => {
    if (!animate) {
      values.forEach(v => {
        v.stopAnimation();
        v.setValue(0);
      });
      return;
    }
    const loops = values.map((v, i) =>
      Animated.loop(
        Animated.sequence([
          Animated.delay((PERIOD / RINGS) * i),
          Animated.timing(v, {
            toValue: 1,
            duration: PERIOD,
            easing: Easing.out(Easing.quad),
            useNativeDriver: true,
          }),
          Animated.timing(v, {
            toValue: 0,
            duration: 0,
            useNativeDriver: true,
          }),
        ]),
      ),
    );
    loops.forEach(l => l.start());
    return () => loops.forEach(l => l.stop());
  }, [animate, values]);

  const ringColor =
    t.scheme === 'dark' ? 'rgba(143,176,255,0.55)' : 'rgba(47,95,239,0.40)';

  return (
    <View
      style={styles.wrap}
      accessible
      accessibilityRole="image"
      accessibilityLabel={
        scanning ? 'Looking for nearby devices' : 'Not scanning'
      }
    >
      {values.map((v, i) => {
        const staticScale = 0.45 + (i + 1) * (0.55 / RINGS);
        const style = animate
          ? {
              opacity: v.interpolate({
                inputRange: [0, 0.15, 1],
                outputRange: [0, 0.9, 0],
              }),
              transform: [
                {
                  scale: v.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0.35, 1],
                  }),
                },
              ],
            }
          : {
              opacity: scanning ? 0.55 - i * 0.14 : 0.25 - i * 0.06,
              transform: [{ scale: staticScale }],
            };
        return (
          <Animated.View
            key={i}
            style={[styles.ring, { borderColor: ringColor }, style]}
          />
        );
      })}
      <View
        style={[
          styles.core,
          { backgroundColor: t.glassFillStrong, borderColor: t.glassBorder },
        ]}
      >
        <Specular color={t.specular} />
        <Icon
          name="phone"
          size={30}
          color={t.scheme === 'dark' ? '#9DB8FF' : t.accent}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    width: SIZE,
    height: SIZE,
    alignItems: 'center',
    justifyContent: 'center',
    alignSelf: 'center',
  },
  ring: {
    position: 'absolute',
    width: SIZE,
    height: SIZE,
    borderRadius: SIZE / 2,
    borderWidth: 1.5,
  },
  core: {
    width: 68,
    height: 68,
    borderRadius: 34,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
});
