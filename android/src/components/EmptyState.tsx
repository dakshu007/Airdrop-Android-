import React from 'react';
import { StyleSheet, View } from 'react-native';
import { spacing } from '../theme/tokens';
import { Drip, Pose } from './Drip';
import { IconBubble } from './IconBubble';
import { IconName } from './Icon';
import { Text } from './Text';

export function EmptyState({
  icon,
  pose,
  title,
  detail,
  children,
}: {
  icon: IconName;
  /** Show Drip in this pose instead of the icon. */
  pose?: Pose;
  title: string;
  detail?: string;
  children?: React.ReactNode;
}) {
  return (
    <View
      style={styles.wrap}
      accessible
      accessibilityLabel={detail ? `${title}. ${detail}` : title}
    >
      {pose ? (
        <Drip pose={pose} size={170} motion="bob" />
      ) : (
        <IconBubble name={icon} size={56} />
      )}
      <Text variant="headline" center>
        {title}
      </Text>
      {detail ? (
        <Text variant="callout" tone="secondary" center>
          {detail}
        </Text>
      ) : null}
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    alignItems: 'center',
    gap: spacing.xs,
    paddingVertical: spacing.xl,
    paddingHorizontal: spacing.md,
  },
});
