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
import { Icon, IconName } from './Icon';
import { Specular } from './Specular';
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
  style?: StyleProp<ViewStyle>;
  accessibilityLabel?: string;
  accessibilityHint?: string;
  testID?: string;
}

export function Button({
  title,
  onPress,
  kind = 'primary',
  icon,
  disabled,
  loading,
  compact,
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
    primary: {
      bg: t.accent,
      fg: t.onAccent,
      border: 'rgba(255,255,255,0.28)',
      tone: 'onAccent' as const,
    },
    secondary: {
      bg: t.glassFill,
      fg: t.textPrimary,
      border: t.glassBorder,
      tone: 'primary' as const,
    },
    destructive: {
      bg: t.dangerSoft,
      fg: t.danger,
      border: t.glassBorder,
      tone: 'danger' as const,
    },
    plain: {
      bg: 'transparent',
      fg: t.scheme === 'dark' ? '#9DB8FF' : t.accent,
      border: 'transparent',
      tone: 'accent' as const,
    },
  }[kind];
  const inactive = disabled || loading;

  return (
    <Animated.View
      style={[{ transform: [{ scale }] }, inactive && styles.disabled, style]}
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
        android_ripple={{ color: 'rgba(255,255,255,0.18)', foreground: true }}
        testID={testID}
        style={[
          styles.base,
          compact ? styles.compact : styles.regular,
          { backgroundColor: palette.bg, borderColor: palette.border },
        ]}
      >
        {kind === 'primary' || kind === 'secondary' ? (
          <Specular color="rgba(255,255,255,0.22)" />
        ) : null}
        <View style={styles.row}>
          {loading ? (
            <ActivityIndicator color={palette.fg} size="small" />
          ) : icon ? (
            <Icon name={icon} size={compact ? 18 : 20} color={palette.fg} />
          ) : null}
          <Text
            variant={compact ? 'subhead' : 'headline'}
            tone={palette.tone}
            center
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
    minHeight: minTouch,
    borderRadius: radii.pill,
    borderWidth: 1,
    overflow: 'hidden',
    justifyContent: 'center',
  },
  regular: { paddingHorizontal: spacing.xl, paddingVertical: spacing.sm },
  compact: { paddingHorizontal: spacing.md, paddingVertical: spacing.xs },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xs,
  },
  disabled: { opacity: 0.5 },
});
