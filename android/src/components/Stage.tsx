import React, { useEffect, useRef } from 'react';
import {
  Animated,
  Modal,
  StatusBar,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { Backdrop, Mood } from '../theme/Backdrop';
import { spacing } from '../theme/tokens';

interface StageProps {
  mood: Mood;
  /** System back. Should be a safe choice (decline, cancel, hide). */
  onRequestClose: () => void;
  accessibilityLabel: string;
  children: React.ReactNode;
}

/**
 * A full-screen moment (pairing, incoming files, a transfer) over its own
 * backdrop. Rises in with a spring; with Reduce motion it fades.
 */
export function Stage({
  mood,
  onRequestClose,
  accessibilityLabel,
  children,
}: StageProps) {
  const insets = useSafeAreaInsets();
  const { height } = useWindowDimensions();
  const reduced = useReducedMotion();
  const progress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    const anim = reduced
      ? Animated.timing(progress, {
          toValue: 1,
          duration: 160,
          useNativeDriver: true,
        })
      : Animated.spring(progress, {
          toValue: 1,
          useNativeDriver: true,
          speed: 14,
          bounciness: 3,
        });
    anim.start();
    return () => anim.stop();
  }, [reduced, progress]);

  return (
    <Modal
      visible
      transparent
      animationType="none"
      statusBarTranslucent
      navigationBarTranslucent
      onRequestClose={onRequestClose}
    >
      <StatusBar barStyle="dark-content" />
      <Animated.View
        accessibilityViewIsModal
        accessibilityLabel={accessibilityLabel}
        style={[
          styles.fill,
          {
            opacity: progress,
            transform: reduced
              ? []
              : [
                  {
                    translateY: progress.interpolate({
                      inputRange: [0, 1],
                      outputRange: [height * 0.12, 0],
                    }),
                  },
                ],
          },
        ]}
      >
        <Backdrop mood={mood} />
        <View
          style={[
            styles.fill,
            {
              paddingTop: insets.top + spacing.sm,
              paddingBottom: insets.bottom + spacing.lg,
              paddingLeft: insets.left + spacing.xl,
              paddingRight: insets.right + spacing.xl,
            },
          ]}
        >
          {children}
        </View>
      </Animated.View>
    </Modal>
  );
}

/** Drip-sized art that shrinks on short screens so the actions always fit. */
export function useArtSize(fraction: number, max: number, min = 150): number {
  const { width, height } = useWindowDimensions();
  return Math.round(
    Math.max(min, Math.min(max, width * 0.86, height * fraction)),
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
});
