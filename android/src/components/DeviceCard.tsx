import React from 'react';
import { StyleSheet, View } from 'react-native';
import { platformLabel } from '../copy';
import type { NearbyDevice } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Badge } from './Badge';
import { GlassCard } from './GlassCard';
import { Icon } from './Icon';
import { IconBubble } from './IconBubble';
import { Text } from './Text';

interface DeviceCardProps {
  device: NearbyDevice;
  onPress: () => void;
  /** What tapping does, e.g. "Send 3 files". */
  actionHint: string;
  disabled?: boolean;
}

export function DeviceCard({
  device,
  onPress,
  actionHint,
  disabled,
}: DeviceCardProps) {
  const t = useTheme();
  const trust = device.trusted ? 'Paired' : 'Not paired';
  return (
    <GlassCard
      onPress={onPress}
      disabled={disabled}
      radius={radii.md}
      accessibilityLabel={`${device.name}, ${platformLabel(
        device.platform,
      )}, ${trust}`}
      accessibilityHint={actionHint}
      style={styles.card}
    >
      <View style={styles.row}>
        <IconBubble
          name={device.platform === 'macos' ? 'laptop' : 'phone'}
          size={48}
        />
        <View style={styles.text}>
          <Text variant="headline" numberOfLines={2}>
            {device.name}
          </Text>
          <View style={styles.meta}>
            <Text variant="footnote" tone="secondary">
              {platformLabel(device.platform)}
            </Text>
            {device.trusted ? (
              <Badge label="Paired" tone="success" icon="shieldCheck" />
            ) : (
              <Badge
                label="New · confirm a code"
                tone="neutral"
                icon="shield"
              />
            )}
          </View>
        </View>
        <Icon
          name="send"
          size={22}
          color={t.scheme === 'dark' ? '#9DB8FF' : t.accent}
        />
      </View>
    </GlassCard>
  );
}

const styles = StyleSheet.create({
  card: { marginBottom: spacing.sm },
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  text: { flex: 1, gap: spacing.xxs },
  meta: {
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
});
