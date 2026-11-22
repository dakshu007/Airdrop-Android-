import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { formatDuration } from '../format';
import { useNow } from '../hooks/useNow';
import type { RoomInfo } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { green, spacing } from '../theme/tokens';
import { Frost } from './Frost';
import { Icon } from './Icon';
import { Text } from './Text';

export function roomMembersText(members: number): string {
  if (members === 0) return 'No one nearby yet';
  return members === 1
    ? '1 nearby in the room'
    : `${members} nearby in the room`;
}

/** The Drip Room this phone is in: name, who's around and time left. Tap for the code / details. */
export function RoomBanner({
  room,
  onPress,
}: {
  room: RoomInfo;
  onPress: () => void;
}) {
  const t = useTheme();
  const now = useNow(30000);
  const left = formatDuration(room.expiresAt - now);
  const meta = `${roomMembersText(room.members)} · ${left} left`;
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`Drip Room ${room.name}. ${meta}`}
      accessibilityHint={
        room.hosting ? 'Shows the room code' : 'Shows the room details'
      }
      android_ripple={{ color: 'rgba(20,154,91,0.12)', foreground: true }}
      style={styles.banner}
    >
      <Frost radius={22} tint="rgba(255,255,255,0.82)" />
      <View style={[styles.icon, { backgroundColor: green }]}>
        <Icon name="users" size={18} color="#FFFFFF" strokeWidth={2} />
      </View>
      <View style={styles.text}>
        <Text variant="subhead" numberOfLines={1}>
          Drip Room · {room.name}
        </Text>
        <Text variant="footnote" tone="secondary" numberOfLines={1}>
          {meta}
        </Text>
      </View>
      <Text variant="subhead" tone="accent">
        {room.hosting ? 'Code' : 'Details'}
      </Text>
      <Icon name="chevronRight" size={16} color={t.link} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: 56,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: 22,
    overflow: 'hidden',
  },
  icon: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1, minWidth: 0 },
});
