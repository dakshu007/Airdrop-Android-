import React from 'react';
import { Text as RNText, TextProps, StyleSheet } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { typography, TypographyVariant } from '../theme/tokens';

type Tone =
  | 'primary'
  | 'secondary'
  | 'tertiary'
  | 'accent'
  | 'success'
  | 'danger'
  | 'warning'
  | 'onAccent';

export interface AppTextProps extends TextProps {
  variant?: TypographyVariant;
  tone?: Tone;
  center?: boolean;
  mono?: boolean;
}

/** Text that follows the type scale and the system font size setting. */
export function Text({
  variant = 'body',
  tone = 'primary',
  center,
  mono,
  style,
  ...rest
}: AppTextProps) {
  const t = useTheme();
  const color = {
    primary: t.textPrimary,
    secondary: t.textSecondary,
    tertiary: t.textTertiary,
    accent: t.scheme === 'dark' ? '#9DB8FF' : t.accent,
    success: t.success,
    danger: t.danger,
    warning: t.warning,
    onAccent: t.onAccent,
  }[tone];
  return (
    <RNText
      {...rest}
      style={[
        typography[variant],
        { color },
        center && styles.center,
        mono && styles.mono,
        style,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  center: { textAlign: 'center' },
  mono: { fontFamily: 'monospace', fontVariant: ['tabular-nums'] },
});
