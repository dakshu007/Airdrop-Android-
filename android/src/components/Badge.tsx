import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Icon, IconName } from './Icon';
import { Text } from './Text';

type Tone = 'success' | 'neutral' | 'warning' | 'danger' | 'accent';

/** Small glass pill label. */
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
    success: { bg: 'rgba(110,235,160,0.18)', fg: t.success, text: 'success' as const },
    neutral: { bg: 'rgba(255,255,255,0.14)', fg: t.textSecondary, text: 'secondary' as const },
    warning: { bg: t.warningSoft, fg: t.warning, text: 'warning' as const },
    danger: { bg: t.dangerSoft, fg: t.danger, text: 'danger' as const },
    accent: { bg: 'rgba(169,205,255,0.18)', fg: '#A9CDFF', text: 'accent' as const },
  }[tone];
  return (
    <View style={[styles.badge, { backgroundColor: colors.bg }]}>
      {icon ? <Icon name={icon} size={13} color={colors.fg} strokeWidth={2} /> : null}
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
    gap: 5,
    paddingHorizontal: spacing.xs + 2,
    paddingVertical: 3,
    borderRadius: radii.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.22)',
  },
});
