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
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Specular } from './Specular';

interface SheetProps {
  visible: boolean;
  /** Called for the system back gesture. Should be a safe choice (cancel / decline). */
  onRequestClose: () => void;
  accessibilityLabel: string;
  children: React.ReactNode;
}

/**
 * Bottom sheet for decisions (pairing, incoming files). It slides up with a
 * spring; reduced motion shows it with a plain fade.
 */
export function Sheet({
  visible,
  onRequestClose,
  accessibilityLabel,
  children,
}: SheetProps) {
  const t = useTheme();
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
      <Animated.View
        style={[styles.scrim, { backgroundColor: t.scrim, opacity: progress }]}
      />
      <View style={styles.anchor} pointerEvents="box-none">
        <Animated.View
          accessibilityViewIsModal
          accessibilityLabel={accessibilityLabel}
          style={[
            styles.sheet,
            {
              backgroundColor: t.glassFillStrong,
              borderColor: t.glassBorder,
              paddingBottom: insets.bottom + spacing.lg,
              marginHorizontal: spacing.xs,
              maxHeight: height - insets.top - spacing.xl,
              opacity: sheetOpacity,
              transform: [{ translateY }],
            },
          ]}
        >
          <Specular color={t.specular} height="30%" />
          <View style={[styles.grabber, { backgroundColor: t.track }]} />
          <ScrollView bounces={false} contentContainerStyle={styles.content}>
            {children}
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
  anchor: { flex: 1, justifyContent: 'flex-end' },
  sheet: {
    borderTopLeftRadius: radii.lg,
    borderTopRightRadius: radii.lg,
    borderBottomLeftRadius: radii.md,
    borderBottomRightRadius: radii.md,
    borderWidth: 1,
    overflow: 'hidden',
    paddingTop: spacing.xs,
  },
  grabber: {
    width: 40,
    height: 5,
    borderRadius: 3,
    alignSelf: 'center',
    marginBottom: spacing.xs,
  },
  content: {
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.sm,
    gap: spacing.md,
  },
});
