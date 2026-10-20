import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import Svg, { Defs, RadialGradient, Rect, Stop } from 'react-native-svg';
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

const SPHERES: Record<Mood, [string, string, string]> = {
  idle: ['#D8F7B4', '#7FD99A', '#2E9E66'],
  off: ['#E4F3D9', '#A9D9B6', '#6BA884'],
  incoming: ['#D8F7B4', '#7FD99A', '#2E9E66'],
  active: ['#E8FBB8', '#9BE68A', '#3BAA70'],
  done: ['#D8F7B4', '#7FD99A', '#2E9E66'],
  failed: ['#FBE3CF', '#E8B08E', '#C4785A'],
};

function Gradient({ mood, id }: { mood: Mood; id: string }) {
  const [a, b, c] = GRADIENTS[mood];
  return (
    <Svg
      style={StyleSheet.absoluteFill}
      width="100%"
      height="100%"
      preserveAspectRatio="none"
    >
      <Defs>
        <RadialGradient id={id} cx="0.5" cy="0" fx="0.5" fy="0" r="1">
          <Stop offset="0" stopColor={a} />
          <Stop offset="0.45" stopColor={b} />
          <Stop offset="1" stopColor={c} />
        </RadialGradient>
      </Defs>
      <Rect x="0" y="0" width="100%" height="100%" fill={`url(#${id})`} />
    </Svg>
  );
}

/** A soft glowing sphere: a radial gradient that fades out, standing in for a blurred ball. */
function Sphere({
  size,
  colors,
  id,
}: {
  size: number;
  colors: [string, string, string];
  id: string;
}) {
  return (
    <Svg width={size} height={size}>
      <Defs>
        <RadialGradient id={id} cx="0.42" cy="0.38" r="0.5">
          <Stop offset="0" stopColor={colors[0]} stopOpacity={0.75} />
          <Stop offset="0.45" stopColor={colors[1]} stopOpacity={0.5} />
          <Stop offset="0.8" stopColor={colors[2]} stopOpacity={0.12} />
          <Stop offset="1" stopColor={colors[2]} stopOpacity={0} />
        </RadialGradient>
      </Defs>
      <Rect x="0" y="0" width={size} height={size} fill={`url(#${id})`} />
    </Svg>
  );
}

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

/** Full-screen background; place first inside a full-screen container. */
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
    >
      {previous ? <Gradient mood={previous} id="bdPrev" /> : null}
      <Animated.View style={[StyleSheet.absoluteFill, { opacity: fade }]}>
        <Gradient mood={shown} id="bdNow" />
      </Animated.View>
      <Animated.View
        style={[
          styles.abs,
          {
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
      >
        <Sphere size={big} colors={SPHERES[shown]} id="bdS1" />
      </Animated.View>
      <Animated.View
        style={[
          styles.abs,
          {
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
      >
        <Sphere size={small} colors={SPHERES[shown]} id="bdS2" />
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  base: { backgroundColor: '#F1FAF3' },
  abs: { position: 'absolute' },
});
