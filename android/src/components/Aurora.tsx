import React, { useEffect, useId, useRef } from 'react';
import {
  Animated,
  Easing,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import Svg, { Circle, Defs, RadialGradient, Stop } from 'react-native-svg';
import { useAppActive } from '../hooks/useAppActive';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { useTheme } from '../theme/ThemeProvider';

interface BlobSpec {
  color: string;
  /** Position as a fraction of the window. */
  x: number;
  y: number;
  /** Diameter as a fraction of the window width. */
  size: number;
  drift: number;
  duration: number;
}

function Blob({
  spec,
  opacity,
  animate,
}: {
  spec: BlobSpec;
  opacity: number;
  animate: boolean;
}) {
  const { width, height } = useWindowDimensions();
  const progress = useRef(new Animated.Value(0)).current;
  const id = `aur${useId().replace(/[^a-zA-Z0-9]/g, '')}`;
  const diameter = width * spec.size;

  useEffect(() => {
    if (!animate) {
      progress.stopAnimation();
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(progress, {
          toValue: 1,
          duration: spec.duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
        Animated.timing(progress, {
          toValue: 0,
          duration: spec.duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [animate, progress, spec.duration]);

  const drift = width * spec.drift;
  const translateX = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [-drift, drift],
  });
  const translateY = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [drift * 0.6, -drift * 0.6],
  });
  const scale = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [1, 1.12],
  });

  return (
    <Animated.View
      renderToHardwareTextureAndroid
      style={[
        styles.blob,
        {
          width: diameter,
          height: diameter,
          left: width * spec.x - diameter / 2,
          top: height * spec.y - diameter / 2,
          transform: [{ translateX }, { translateY }, { scale }],
        },
      ]}
    >
      <Svg width={diameter} height={diameter}>
        <Defs>
          <RadialGradient id={id} cx="50%" cy="50%" r="50%">
            <Stop offset="0" stopColor={spec.color} stopOpacity={opacity} />
            <Stop
              offset="0.55"
              stopColor={spec.color}
              stopOpacity={opacity * 0.35}
            />
            <Stop offset="1" stopColor={spec.color} stopOpacity={0} />
          </RadialGradient>
        </Defs>
        <Circle
          cx={diameter / 2}
          cy={diameter / 2}
          r={diameter / 2}
          fill={`url(#${id})`}
        />
      </Svg>
    </Animated.View>
  );
}

/**
 * The backdrop every glass surface sits on: large, soft color fields that
 * drift very slowly. Static when reduced motion is on or the app is in the
 * background.
 */
export function Aurora() {
  const t = useTheme();
  const reduced = useReducedMotion();
  const active = useAppActive();
  const animate = !reduced && active;
  const [a, b, c, d] = t.aurora;
  const blobs: BlobSpec[] = [
    { color: a, x: 0.1, y: 0.08, size: 1.25, drift: 0.08, duration: 23000 },
    { color: b, x: 0.95, y: 0.28, size: 1.1, drift: 0.1, duration: 29000 },
    { color: c, x: 0.05, y: 0.72, size: 1.15, drift: 0.07, duration: 31000 },
    { color: d, x: 0.9, y: 0.95, size: 1.0, drift: 0.09, duration: 27000 },
  ];
  return (
    <View
      pointerEvents="none"
      style={[StyleSheet.absoluteFill, { backgroundColor: t.background }]}
      importantForAccessibility="no-hide-descendants"
    >
      {blobs.map((spec, i) => (
        <Blob key={i} spec={spec} opacity={t.auroraOpacity} animate={animate} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  blob: { position: 'absolute' },
});
