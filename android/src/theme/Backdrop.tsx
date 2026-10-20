import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';

/**
 * The background follows what is happening: mint when idle, cooler when
 * receiving is off, lime while files move, deeper green when they arrive and
 * a warm blush when something failed.
 */
export type Mood = 'idle' | 'off' | 'incoming' | 'active' | 'done' | 'failed';

const GRADIENTS: Record<Mood, [string, string, string]> = {
  idle: ['#FFFFFF', '#F1FAF3', '#DDF3E3'],
  off: ['#FFFFFF', '#F2F6F3', '#E1ECE5'],
  incoming: ['#FFFFFF', '#EAF7EE', '#CFEBD8'],
  active: ['#FFFFFF', '#F2FCE6', '#D9F5C4'],
  done: ['#FFFFFF', '#E6F7EA', '#BFE8CB'],
  failed: ['#FFFFFF', '#FBF5F1', '#F1E4DC'],
};

/** Inner, middle and edge colour of the soft spheres (rgb triplets). */
const SPHERES: Record<Mood, [string, string, string]> = {
  idle: ['216,247,180', '127,217,154', '46,158,102'],
  off: ['228,243,217', '169,217,182', '107,168,132'],
  incoming: ['216,247,180', '127,217,154', '46,158,102'],
  active: ['232,251,184', '155,230,138', '59,170,112'],
  done: ['216,247,180', '127,217,154', '46,158,102'],
  failed: ['251,227,207', '232,176,142', '196,120,90'],
};

const gradient = (mood: Mood) => {
  const [a, b, c] = GRADIENTS[mood];
  return `radial-gradient(ellipse 120% 75% at 50% 0%, ${a} 0%, ${b} 45%, ${c} 100%)`;
};

/** A glowing ball that fades to nothing at its edge, standing in for a blurred sphere. */
const sphere = (mood: Mood) => {
  const [a, b, c] = SPHERES[mood];
  return `radial-gradient(circle closest-side at 42% 38%, rgba(${a},0.75) 0%, rgba(${b},0.5) 45%, rgba(${c},0.12) 80%, rgba(${c},0) 100%)`;
};

function useDrift(reduced: boolean, duration: number) {
  const v = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (reduced) {
      v.setValue(0);
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([
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
    loop.start();
    return () => loop.stop();
  }, [reduced, duration, v]);
  return v;
}

/**
 * Full-screen background drawn with native gradients (nothing to measure or
 * rasterise, so it is ready in the first frame). Place first inside a
 * full-screen container.
 */
export function Backdrop({ mood }: { mood: Mood }) {
  const reduced = useReducedMotion();
  const { width, height } = useWindowDimensions();
  const [shown, setShown] = useState(mood);
  const [previous, setPrevious] = useState<Mood | null>(null);
  const fade = useRef(new Animated.Value(1)).current;
  const a = useDrift(reduced, 5200);
  const b = useDrift(reduced, 4100);

  useEffect(() => {
    if (mood === shown) return;
    setPrevious(shown);
    setShown(mood);
    fade.setValue(0);
    Animated.timing(fade, {
      toValue: 1,
      duration: reduced ? 0 : 600,
      useNativeDriver: true,
    }).start(() => setPrevious(null));
  }, [mood, shown, fade, reduced]);

  const big = Math.round(width * 0.62);
  const small = Math.round(width * 0.34);
  return (
    <View
      style={[StyleSheet.absoluteFill, styles.base]}
      pointerEvents="none"
      accessible={false}
      importantForAccessibility="no-hide-descendants"
    >
      {previous ? (
        <View
          style={[
            StyleSheet.absoluteFill,
            { backgroundImage: gradient(previous) },
          ]}
        />
      ) : null}
      <Animated.View
        style={[
          StyleSheet.absoluteFill,
          { opacity: fade, backgroundImage: gradient(shown) },
        ]}
      />
      <Animated.View
        style={[
          styles.abs,
          {
            width: big,
            height: big,
            left: -big * 0.42,
            top: height * 0.62,
            backgroundImage: sphere(shown),
            transform: [
              {
                translateX: a.interpolate({
                  inputRange: [0, 1],
                  outputRange: [0, 18],
                }),
              },
              {
                translateY: a.interpolate({
                  inputRange: [0, 1],
                  outputRange: [0, -22],
                }),
              },
            ],
          },
        ]}
      />
      <Animated.View
        style={[
          styles.abs,
          {
            width: small,
            height: small,
            right: -small * 0.3,
            top: height * 0.17,
            backgroundImage: sphere(shown),
            transform: [
              {
                translateX: b.interpolate({
                  inputRange: [0, 1],
                  outputRange: [0, -14],
                }),
              },
              {
                translateY: b.interpolate({
                  inputRange: [0, 1],
                  outputRange: [0, 18],
                }),
              },
            ],
          },
        ]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  base: { backgroundColor: '#F1FAF3' },
  abs: { position: 'absolute' },
});
