import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  Image,
  ImageSourcePropType,
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

/** Pre-drawn gradients (scripts/make_ui_textures.py): one texture each, no per-pixel work. */
const BACKDROPS: Record<Mood, ImageSourcePropType> = {
  idle: require('../assets/ui/backdrop-idle.jpg'),
  off: require('../assets/ui/backdrop-off.jpg'),
  incoming: require('../assets/ui/backdrop-incoming.jpg'),
  active: require('../assets/ui/backdrop-active.jpg'),
  done: require('../assets/ui/backdrop-done.jpg'),
  failed: require('../assets/ui/backdrop-failed.jpg'),
};

const SPHERES: Record<Mood, ImageSourcePropType> = {
  idle: require('../assets/ui/sphere-green.png'),
  off: require('../assets/ui/sphere-cool.png'),
  incoming: require('../assets/ui/sphere-green.png'),
  active: require('../assets/ui/sphere-lime.png'),
  done: require('../assets/ui/sphere-green.png'),
  failed: require('../assets/ui/sphere-warm.png'),
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
        <Image
          source={BACKDROPS[previous]}
          style={StyleSheet.absoluteFill}
          resizeMode="stretch"
          fadeDuration={0}
        />
      ) : null}
      <Animated.Image
        source={BACKDROPS[shown]}
        style={[StyleSheet.absoluteFill, { opacity: fade }]}
        resizeMode="stretch"
        fadeDuration={0}
      />
      <Animated.Image
        source={SPHERES[shown]}
        fadeDuration={0}
        style={[
          styles.abs,
          {
            width: big,
            height: big,
            left: -big * 0.42,
            top: height * 0.62,
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
      <Animated.Image
        source={SPHERES[shown]}
        fadeDuration={0}
        style={[
          styles.abs,
          {
            width: small,
            height: small,
            right: -small * 0.3,
            top: height * 0.17,
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
