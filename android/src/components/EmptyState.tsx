import React from 'react';
import { StyleSheet, View } from 'react-native';
import { spacing } from '../theme/tokens';
import { IconBubble } from './IconBubble';
import { IconName } from './Icon';
import { Text } from './Text';

export function EmptyState({
  icon,
  title,
  detail,
  children,
}: {
  icon: IconName;
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
      <IconBubble name={icon} size={56} />
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
