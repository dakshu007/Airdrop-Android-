import React, { useEffect, useRef } from 'react';
import { Animated, Easing, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { typography } from '../theme/tokens';
import { Text } from './Text';

const STAGGER = 90;

/**
 * The pairing code as six glass tiles (three, a gap, three) that flip in one
 * by one. `onTick` fires as each tile lands, for a light haptic tick.
 */
export function CodeTiles({
  code,
  onTick,
}: {
  code: string;
  onTick?: () => void;
}) {
  const reduced = useReducedMotion();
  const digits = code.split('');
  const values = useRef(digits.map(() => new Animated.Value(0))).current;
  const tick = useRef(onTick);
  tick.current = onTick;

  useEffect(() => {
    if (reduced) {
      values.forEach(v => v.setValue(1));
      return;
    }
    values.forEach(v => v.setValue(0));
    const timers = values.map((_, i) =>
      setTimeout(() => tick.current?.(), i * STAGGER + 300),
    );
    const anim = Animated.stagger(
      STAGGER,
      values.map(v =>
        Animated.timing(v, {
          toValue: 1,
          duration: 520,
          easing: Easing.bezier(0.2, 0.8, 0.2, 1),
          useNativeDriver: true,
        }),
      ),
    );
    anim.start();
    return () => {
      anim.stop();
      timers.forEach(clearTimeout);
    };
  }, [code, reduced, values]);

  return (
    <View style={styles.row} importantForAccessibility="no-hide-descendants">
      {digits.map((digit, i) => {
        const v = values[i] ?? values[0];
        return (
          <React.Fragment key={i}>
            {i === 3 ? <View style={styles.gap} /> : null}
            <Animated.View
              style={[
                styles.tile,
                {
                  opacity: v.interpolate({
                    inputRange: [0, 0.6, 1],
                    outputRange: [0, 1, 1],
                  }),
                  transform: [
                    { perspective: 300 },
                    {
                      rotateX: v.interpolate({
                        inputRange: [0, 0.6, 1],
                        outputRange: ['-90deg', '12deg', '0deg'],
                      }),
                    },
                    {
                      translateY: v.interpolate({
                        inputRange: [0, 0.6, 1],
                        outputRange: [-6, 0, 0],
                      }),
                    },
                  ],
                },
              ]}
            >
              <Text
                variant="code"
                style={styles.digit}
                maxFontSizeMultiplier={1.2}
              >
                {digit}
              </Text>
            </Animated.View>
          </React.Fragment>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  gap: { width: 8 },
  tile: {
    width: 44,
    height: 60,
    borderRadius: 14,
    backgroundColor: 'rgba(255,255,255,0.92)',
    borderWidth: 1,
    borderColor: '#D5E7DB',
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#185434',
    shadowOpacity: 0.1,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 4 },
    elevation: 2,
  },
  digit: {
    fontVariant: ['tabular-nums'],
    lineHeight: typography.code.lineHeight,
  },
});
