import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { GlassCard } from './GlassCard';
import { Icon, IconName } from './Icon';
import { Text } from './Text';

type Tone = 'warning' | 'danger' | 'info';

/** Inline, non-blocking message with an optional action. */
export function Notice({
  tone = 'info',
  icon,
  title,
  detail,
  action,
}: {
  tone?: Tone;
  icon?: IconName;
  title: string;
  detail?: string;
  action?: React.ReactNode;
}) {
  const t = useTheme();
  const color = {
    warning: t.warning,
    danger: t.danger,
    info: t.scheme === 'dark' ? '#9DB8FF' : t.accent,
  }[tone];
  const tint = {
    warning: t.warningSoft,
    danger: t.dangerSoft,
    info: t.accentSoft,
  }[tone];
  const fallbackIcon: IconName = tone === 'info' ? 'info' : 'alert';
  return (
    <GlassCard
      tint={tint}
      radius={radii.md}
      accessibilityLabel={
        action ? undefined : detail ? `${title}. ${detail}` : title
      }
    >
      <View style={styles.row}>
        <Icon name={icon ?? fallbackIcon} color={color} size={22} />
        <View style={styles.text}>
          <Text variant="headline">{title}</Text>
          {detail ? (
            <Text variant="footnote" tone="secondary">
              {detail}
            </Text>
          ) : null}
        </View>
      </View>
      {action ? <View style={styles.action}>{action}</View> : null}
    </GlassCard>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: spacing.sm, alignItems: 'flex-start' },
  text: { flex: 1, gap: spacing.xxs },
  action: { marginTop: spacing.sm, alignItems: 'flex-start' },
});
