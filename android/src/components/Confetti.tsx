import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';

const PIECES: { dx: number; dy: number; color: string; delay: number }[] = [
  { dx: -150, dy: -170, color: '#149A5B', delay: 100 },
  { dx: 140, dy: -190, color: '#F2C14E', delay: 140 },
  { dx: -110, dy: -240, color: '#9BE6A6', delay: 180 },
  { dx: 100, dy: -250, color: '#149A5B', delay: 120 },
  { dx: -170, dy: -60, color: '#F2C14E', delay: 200 },
  { dx: 170, dy: -80, color: '#6FD493', delay: 160 },
  { dx: -40, dy: -280, color: '#F2C14E', delay: 220 },
  { dx: 40, dy: -270, color: '#0F1D16', delay: 110 },
  { dx: -190, dy: -150, color: '#6FD493', delay: 240 },
  { dx: 190, dy: -150, color: '#9BE6A6', delay: 260 },
  { dx: -80, dy: -120, color: '#149A5B', delay: 300 },
  { dx: 80, dy: -130, color: '#F2C14E', delay: 280 },
];

/** A one-shot burst of confetti from the centre of its box. Hidden with Reduce motion. */
export function Confetti() {
  const reduced = useReducedMotion();
  const values = useRef(PIECES.map(() => new Animated.Value(0))).current;

  useEffect(() => {
    if (reduced) return;
    const anim = Animated.parallel(
      values.map((v, i) =>
        Animated.sequence([
          Animated.delay(PIECES[i].delay),
          Animated.timing(v, {
            toValue: 1,
            duration: 1600,
            easing: Easing.bezier(0.15, 0.7, 0.3, 1),
            useNativeDriver: true,
          }),
        ]),
      ),
    );
    anim.start();
    return () => anim.stop();
  }, [reduced, values]);

  if (reduced) return null;
  return (
    <View
      pointerEvents="none"
      style={[StyleSheet.absoluteFill, styles.center]}
      importantForAccessibility="no-hide-descendants"
    >
      {PIECES.map((p, i) => {
        const v = values[i];
        return (
          <Animated.View
            key={i}
            style={[
              styles.piece,
              {
                backgroundColor: p.color,
                opacity: v.interpolate({
                  inputRange: [0, 0.15, 0.8, 1],
                  outputRange: [0, 1, 1, 0],
                }),
                transform: [
                  {
                    translateX: v.interpolate({
                      inputRange: [0, 1],
                      outputRange: [0, p.dx],
                    }),
                  },
                  {
                    translateY: v.interpolate({
                      inputRange: [0, 1],
                      outputRange: [0, p.dy],
                    }),
                  },
                  {
                    rotate: v.interpolate({
                      inputRange: [0, 1],
                      outputRange: ['0deg', '260deg'],
                    }),
                  },
                  {
                    scale: v.interpolate({
                      inputRange: [0, 1],
                      outputRange: [0.4, 1],
                    }),
                  },
                ],
              },
            ]}
          />
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  center: { alignItems: 'center', justifyContent: 'center' },
  piece: { position: 'absolute', width: 10, height: 14, borderRadius: 3 },
});
