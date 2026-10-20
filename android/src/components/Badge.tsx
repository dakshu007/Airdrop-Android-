import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Icon, IconName } from './Icon';
import { Text } from './Text';

type Tone = 'success' | 'neutral' | 'warning' | 'danger' | 'accent';

export function Badge({
  label,
  tone = 'neutral',
  icon,
}: {
  label: string;
  tone?: Tone;
  icon?: IconName;
}) {
  const t = useTheme();
  const colors = {
    success: { bg: t.successSoft, fg: t.success, text: 'success' as const },
    neutral: { bg: t.track, fg: t.textSecondary, text: 'secondary' as const },
    warning: { bg: t.warningSoft, fg: t.warning, text: 'warning' as const },
    danger: { bg: t.dangerSoft, fg: t.danger, text: 'danger' as const },
    accent: {
      bg: t.accentSoft,
      fg: t.scheme === 'dark' ? '#9DB8FF' : t.accent,
      text: 'accent' as const,
    },
  }[tone];
  return (
    <View style={[styles.badge, { backgroundColor: colors.bg }]}>
      {icon ? (
        <Icon name={icon} size={14} color={colors.fg} strokeWidth={2} />
      ) : null}
      <Text variant="caption" tone={colors.text}>
        {label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: spacing.xxs,
    paddingHorizontal: spacing.xs,
    paddingVertical: 3,
    borderRadius: radii.pill,
  },
});
