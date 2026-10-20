import React, { useEffect, useRef } from 'react';
import { Animated, Pressable, StyleSheet, View } from 'react-native';
import { useReducedMotion } from '../hooks/useReducedMotion';

const W = 54;
const H = 32;
const KNOB = 26;

/** Glass switch: frosted track when off, soft green when on, white knob with a spring. */
export function Toggle({
  value,
  onValueChange,
  accessibilityLabel,
  accessibilityHint,
  disabled,
}: {
  value: boolean;
  onValueChange: (next: boolean) => void;
  accessibilityLabel: string;
  accessibilityHint?: string;
  disabled?: boolean;
}) {
  const reduced = useReducedMotion();
  const v = useRef(new Animated.Value(value ? 1 : 0)).current;

  useEffect(() => {
    if (reduced) {
      v.setValue(value ? 1 : 0);
    } else {
      Animated.spring(v, {
        toValue: value ? 1 : 0,
        useNativeDriver: false,
        speed: 22,
        bounciness: 7,
      }).start();
    }
  }, [value, reduced, v]);

  return (
    <Pressable
      onPress={() => onValueChange(!value)}
      disabled={disabled}
      accessibilityRole="switch"
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ checked: value, disabled: !!disabled }}
      hitSlop={8}
      style={[styles.hit, disabled && styles.disabled]}
    >
      <Animated.View
        style={[
          styles.track,
          {
            backgroundColor: v.interpolate({
              inputRange: [0, 1],
              outputRange: ['rgba(255,255,255,0.16)', 'rgba(76,217,128,0.95)'],
            }),
            borderColor: v.interpolate({
              inputRange: [0, 1],
              outputRange: ['rgba(255,255,255,0.38)', 'rgba(170,255,200,0.7)'],
            }),
          },
        ]}
      >
        <Animated.View
          style={[
            styles.knob,
            {
              transform: [
                {
                  translateX: v.interpolate({
                    inputRange: [0, 1],
                    outputRange: [2, W - KNOB - 4],
                  }),
                },
              ],
            },
          ]}
        >
          <View style={styles.knobShine} />
        </Animated.View>
      </Animated.View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  hit: { minHeight: 48, justifyContent: 'center' },
  disabled: { opacity: 0.45 },
  track: {
    width: W,
    height: H,
    borderRadius: H / 2,
    borderWidth: 1,
    justifyContent: 'center',
  },
  knob: {
    width: KNOB,
    height: KNOB,
    borderRadius: KNOB / 2,
    backgroundColor: '#FFFFFF',
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 4,
    shadowOffset: { width: 0, height: 2 },
    elevation: 3,
    overflow: 'hidden',
  },
  knobShine: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: KNOB / 2,
    backgroundColor: 'rgba(0,0,0,0.04)',
  },
});
