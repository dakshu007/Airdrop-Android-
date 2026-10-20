import React, { useEffect, useRef } from 'react';
import {
  Animated,
  Modal,
  ScrollView,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { spacing } from '../theme/tokens';
import { Frost } from './Frost';

const SHEET_RADIUS = 34;

interface SheetProps {
  visible: boolean;
  /** Called for the system back gesture. Should be a safe choice (cancel / decline). */
  onRequestClose: () => void;
  accessibilityLabel: string;
  children: React.ReactNode;
}

/**
 * Bottom sheet (e.g. the full list of nearby devices). It slides up with a
 * spring; reduced motion shows it with a plain fade.
 */
export function Sheet({
  visible,
  onRequestClose,
  accessibilityLabel,
  children,
}: SheetProps) {
  const insets = useSafeAreaInsets();
  const { height } = useWindowDimensions();
  const reduced = useReducedMotion();
  const progress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (!visible) {
      progress.setValue(0);
      return;
    }
    if (reduced) {
      Animated.timing(progress, {
        toValue: 1,
        duration: 150,
        useNativeDriver: true,
      }).start();
    } else {
      Animated.spring(progress, {
        toValue: 1,
        useNativeDriver: true,
        speed: 14,
        bounciness: 4,
      }).start();
    }
  }, [visible, reduced, progress]);

  const translateY = reduced
    ? 0
    : progress.interpolate({
        inputRange: [0, 1],
        outputRange: [Math.min(480, height * 0.6), 0],
      });

  const sheetOpacity = reduced ? progress : 1;

  return (
    <Modal
      visible={visible}
      transparent
      animationType="none"
      statusBarTranslucent
      navigationBarTranslucent
      onRequestClose={onRequestClose}
    >
      <Animated.View style={[styles.scrim, { opacity: progress }]} />
      <View style={styles.anchor} pointerEvents="box-none">
        <Animated.View
          accessibilityViewIsModal
          accessibilityLabel={accessibilityLabel}
          style={[
            styles.sheet,
            {
              marginBottom: insets.bottom + spacing.sm,
              maxHeight: height - insets.top - spacing.xl,
              opacity: sheetOpacity,
              transform: [{ translateY }],
            },
          ]}
        >
          <Frost radius={SHEET_RADIUS} tint="rgba(255,255,255,0.94)" />
          <View style={styles.grabber} />
          <ScrollView bounces={false} contentContainerStyle={styles.content}>
            {children}
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'rgba(15,29,22,0.32)',
  },
  anchor: { flex: 1, justifyContent: 'flex-end' },
  sheet: {
    borderRadius: SHEET_RADIUS,
    marginHorizontal: spacing.sm,
    overflow: 'hidden',
    paddingTop: spacing.xs,
  },
  grabber: {
    width: 40,
    height: 5,
    borderRadius: 3,
    alignSelf: 'center',
    marginBottom: spacing.xs,
    backgroundColor: '#C7DDCD',
  },
  content: {
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.sm,
    paddingBottom: spacing.xl,
    gap: spacing.md,
  },
});
