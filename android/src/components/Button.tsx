import React, { useRef } from 'react';
import {
  ActivityIndicator,
  Animated,
  Pressable,
  StyleProp,
  StyleSheet,
  View,
  ViewStyle,
} from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, radii, spacing } from '../theme/tokens';
import { Frost } from './Frost';
import { Icon, IconName } from './Icon';
import { Text } from './Text';

type Kind = 'primary' | 'secondary' | 'destructive' | 'plain';

interface ButtonProps {
  title: string;
  onPress: () => void;
  kind?: Kind;
  icon?: IconName;
  disabled?: boolean;
  loading?: boolean;
  compact?: boolean;
  /** The tall pill used for a screen's main action. */
  large?: boolean;
  style?: StyleProp<ViewStyle>;
  accessibilityLabel?: string;
  accessibilityHint?: string;
  testID?: string;
}

/**
 * Primary is the black pill; secondary is white glass; plain is a green link.
 * Buttons compress slightly with a spring when pressed.
 */
export function Button({
  title,
  onPress,
  kind = 'primary',
  icon,
  disabled,
  loading,
  compact,
  large,
  style,
  accessibilityLabel,
  accessibilityHint,
  testID,
}: ButtonProps) {
  const t = useTheme();
  const scale = useRef(new Animated.Value(1)).current;
  const springTo = (value: number) =>
    Animated.spring(scale, {
      toValue: value,
      useNativeDriver: true,
      speed: 40,
      bounciness: 8,
    }).start();

  const palette = {
    primary: { bg: t.accent, fg: t.onAccent, tone: 'onAccent' as const },
    secondary: {
      bg: 'transparent',
      fg: t.textPrimary,
      tone: 'primary' as const,
    },
    destructive: { bg: t.dangerSoft, fg: t.danger, tone: 'danger' as const },
    plain: { bg: 'transparent', fg: t.link, tone: 'accent' as const },
  }[kind];
  const inactive = disabled || loading;
  const height = large ? 58 : compact ? minTouch - 4 : 54;

  return (
    <Animated.View
      style={[
        { transform: [{ scale }] },
        kind === 'primary' && !inactive && styles.lift,
        inactive && styles.disabled,
        style,
      ]}
    >
      <Pressable
        onPress={onPress}
        disabled={inactive}
        onPressIn={() => springTo(0.96)}
        onPressOut={() => springTo(1)}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel ?? title}
        accessibilityHint={accessibilityHint}
        accessibilityState={{ disabled: !!inactive, busy: !!loading }}
        android_ripple={{
          color:
            kind === 'primary'
              ? 'rgba(255,255,255,0.14)'
              : 'rgba(20,154,91,0.10)',
          foreground: true,
        }}
        testID={testID}
        style={[
          styles.base,
          { minHeight: height, backgroundColor: palette.bg },
          compact ? styles.compact : styles.regular,
        ]}
      >
        {kind === 'secondary' ? <Frost radius={radii.pill} /> : null}
        <View style={styles.row}>
          {loading ? (
            <ActivityIndicator color={palette.fg} size="small" />
          ) : icon ? (
            <Icon
              name={icon}
              size={compact ? 17 : 19}
              color={palette.fg}
              strokeWidth={2}
            />
          ) : null}
          <Text
            variant={compact ? 'subhead' : 'headline'}
            tone={palette.tone}
            center
            style={large ? styles.largeText : undefined}
          >
            {title}
          </Text>
        </View>
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  base: {
    borderRadius: radii.pill,
    overflow: 'hidden',
    justifyContent: 'center',
  },
  regular: { paddingHorizontal: spacing.xl, paddingVertical: spacing.xs },
  compact: { paddingHorizontal: spacing.md, paddingVertical: spacing.xxs },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xs,
  },
  largeText: { fontSize: 17 },
  lift: {
    borderRadius: radii.pill,
    boxShadow: '0px 14px 30px rgba(15,29,22,0.22)',
  },
  disabled: { opacity: 0.45 },
});
