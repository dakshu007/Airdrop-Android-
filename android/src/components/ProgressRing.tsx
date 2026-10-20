import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import Svg, {
  Circle,
  Defs,
  LinearGradient,
  RadialGradient,
  Stop,
} from 'react-native-svg';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { green, greenLight } from '../theme/tokens';

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

interface ProgressRingProps {
  /** 0…1, or null while waiting (shows an empty ring). */
  value: number | null;
  size: number;
  color?: string;
  /** Sweeping light on the ring while files move. */
  sheen?: boolean;
  accessibilityLabel: string;
  children?: React.ReactNode;
}

/**
 * Thick green ring around a soft white disc. Content (Drip and the
 * percentage) sits inside the disc.
 */
export function ProgressRing({
  value,
  size,
  color,
  sheen,
  accessibilityLabel,
  children,
}: ProgressRingProps) {
  const reduced = useReducedMotion();
  const stroke = 12;
  const r = (size - stroke) / 2;
  const circumference = 2 * Math.PI * r;
  const clamped =
    value === null
      ? 0
      : Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
  const progress = useRef(new Animated.Value(clamped)).current;
  const spin = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (reduced) {
      progress.setValue(clamped);
      return;
    }
    Animated.timing(progress, {
      toValue: clamped,
      duration: 420,
      easing: Easing.out(Easing.quad),
      useNativeDriver: false,
    }).start();
  }, [clamped, reduced, progress]);

  useEffect(() => {
    if (!sheen || reduced) {
      spin.setValue(0);
      return;
    }
    const anim = Animated.loop(
      Animated.timing(spin, {
        toValue: 1,
        duration: 2800,
        easing: Easing.linear,
        useNativeDriver: true,
      }),
    );
    anim.start();
    return () => anim.stop();
  }, [sheen, reduced, spin]);

  const percent = Math.round(clamped * 100);
  const ringColor = color ?? green;
  return (
    <View
      style={{ width: size, height: size }}
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={{
        min: 0,
        max: 100,
        now: percent,
        text: `${percent} percent`,
      }}
    >
      <Svg width={size} height={size} style={StyleSheet.absoluteFill}>
        <Defs>
          <LinearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="1">
            <Stop offset="0" stopColor={ringColor} />
            <Stop offset="0.5" stopColor={color ? ringColor : greenLight} />
            <Stop offset="1" stopColor={ringColor} />
          </LinearGradient>
          <RadialGradient id="discGrad" cx="0.5" cy="0.35" r="0.6">
            <Stop offset="0" stopColor="#FFFFFF" />
            <Stop offset="0.6" stopColor="#F2FBF4" />
            <Stop offset="1" stopColor="#E2F5E8" />
          </RadialGradient>
        </Defs>
        <Circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          stroke="rgba(20,154,91,0.12)"
          strokeWidth={stroke}
          fill="none"
        />
        <AnimatedCircle
          cx={size / 2}
          cy={size / 2}
          r={r}
          stroke="url(#ringGrad)"
          strokeWidth={stroke}
          strokeLinecap="round"
          fill="none"
          strokeDasharray={`${circumference} ${circumference}`}
          strokeDashoffset={progress.interpolate({
            inputRange: [0, 1],
            outputRange: [circumference, 0],
          })}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
        />
        <Circle
          cx={size / 2}
          cy={size / 2}
          r={r - stroke / 2 - 1}
          fill="url(#discGrad)"
        />
      </Svg>
      {sheen && !reduced ? (
        <Animated.View
          pointerEvents="none"
          style={[
            StyleSheet.absoluteFill,
            {
              transform: [
                {
                  rotate: spin.interpolate({
                    inputRange: [0, 1],
                    outputRange: ['0deg', '360deg'],
                  }),
                },
              ],
            },
          ]}
        >
          <Svg width={size} height={size}>
            <Defs>
              <LinearGradient id="sheenGrad" x1="0" y1="0" x2="1" y2="0">
                <Stop offset="0" stopColor="#FFFFFF" stopOpacity={0} />
                <Stop offset="0.5" stopColor="#FFFFFF" stopOpacity={0.8} />
                <Stop offset="1" stopColor="#FFFFFF" stopOpacity={0} />
              </LinearGradient>
            </Defs>
            <Circle
              cx={size / 2}
              cy={size / 2}
              r={r}
              stroke="url(#sheenGrad)"
              strokeWidth={stroke}
              fill="none"
              strokeDasharray={`${circumference * 0.11} ${circumference}`}
            />
          </Svg>
        </Animated.View>
      ) : null}
      <View style={[StyleSheet.absoluteFill, styles.center]}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  center: { alignItems: 'center', justifyContent: 'center' },
});
