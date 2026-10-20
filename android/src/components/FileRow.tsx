import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { formatBytes } from '../format';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, spacing } from '../theme/tokens';
import { Icon, iconForMime } from './Icon';
import { Text } from './Text';

interface FileRowProps {
  name: string;
  size: number | null;
  mime: string | null;
  onRemove?: () => void;
}

export function FileRow({ name, size, mime, onRemove }: FileRowProps) {
  const t = useTheme();
  const sizeText = size === null ? 'Size unknown' : formatBytes(size);
  return (
    <View style={styles.row}>
      <View style={[styles.thumb, { backgroundColor: t.track }]}>
        <Icon name={iconForMime(mime)} size={20} color={t.textSecondary} />
      </View>
      <View
        style={styles.text}
        accessible
        accessibilityLabel={`${name}, ${sizeText}`}
      >
        <Text variant="callout" numberOfLines={2}>
          {name}
        </Text>
        <Text variant="footnote" tone="tertiary">
          {sizeText}
        </Text>
      </View>
      {onRemove ? (
        <Pressable
          onPress={onRemove}
          hitSlop={8}
          accessibilityRole="button"
          accessibilityLabel={`Remove ${name}`}
          style={styles.remove}
        >
          <Icon name="x" size={18} color={t.textSecondary} />
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: minTouch,
  },
  thumb: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1 },
  remove: {
    width: minTouch,
    height: minTouch,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
