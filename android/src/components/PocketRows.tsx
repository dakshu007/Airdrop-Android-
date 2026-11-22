import React from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  StyleSheet,
  View,
} from 'react-native';
import { queueError } from '../copy';
import {
  deleteLabel,
  filesTitle,
  formatBytes,
  formatDuration,
  relativeTime,
  sumSizes,
} from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { PocketItem, QueuedSend } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, spacing } from '../theme/tokens';
import { Button } from './Button';
import { Icon, iconForMime } from './Icon';
import { Ripple } from './Ripple';
import { Text } from './Text';

function queueTitle(item: QueuedSend): string {
  if (item.kind === 'link') return item.preview ?? 'Link';
  if (item.kind === 'text') return 'Text';
  return filesTitle(item.files);
}

function queueStatus(item: QueuedSend, searching: boolean): string {
  if (!item.paired) return `${item.deviceName} was forgotten`;
  switch (item.status) {
    case 'sending':
      return 'Sending now';
    case 'failed':
      return queueError(item.error);
    case 'waiting':
      return searching
        ? `Looking for ${item.deviceName}…`
        : `Goes when ${item.deviceName} is nearby`;
  }
}

/** A "Send when nearby" item: what, to whom, and where it stands. */
export function QueueRow({
  item,
  searching,
}: {
  item: QueuedSend;
  searching: boolean;
}) {
  const t = useTheme();
  const title = queueTitle(item);
  const failed = item.status === 'failed' || !item.paired;
  const { total, unknown } = sumSizes(item.files);
  const size =
    item.kind === 'files'
      ? unknown && total === 0
        ? 'size unknown'
        : `${formatBytes(total)}${unknown ? '+' : ''}`
      : item.kind === 'link'
      ? 'link'
      : 'text';
  const status = queueStatus(item, searching);
  const extra =
    item.expiresAfter !== null
      ? ` · auto-deletes ${formatDuration(
          item.expiresAfter * 1000,
        )} after arriving`
      : '';
  const meta = `To ${item.deviceName} · ${size}${extra}`;

  return (
    <View style={styles.row}>
      <View
        style={styles.main}
        accessible
        accessibilityLabel={`${title}. ${meta}. ${status}`}
      >
        <View
          style={[
            styles.bubble,
            { backgroundColor: failed ? t.dangerSoft : t.accentSoft },
          ]}
        >
          {item.status === 'sending' ? (
            <ActivityIndicator size="small" color={t.link} />
          ) : item.status === 'waiting' && searching ? (
            <Ripple size={40} rings={2} duration={1800}>
              <Icon name="radar" size={18} color={t.link} />
            </Ripple>
          ) : (
            <Icon
              name={failed ? 'alert' : 'clock'}
              size={18}
              color={failed ? t.danger : t.link}
            />
          )}
        </View>
        <View style={styles.text}>
          <Text variant="callout" numberOfLines={1}>
            {title}
          </Text>
          <Text variant="footnote" tone="secondary" numberOfLines={2}>
            {meta}
          </Text>
          <Text
            variant="footnote"
            tone={
              failed
                ? 'danger'
                : item.status === 'sending'
                ? 'accent'
                : 'secondary'
            }
            numberOfLines={2}
          >
            {status}
          </Text>
        </View>
      </View>
      <View style={styles.actions}>
        {item.status === 'failed' && item.paired ? (
          <Button
            title="Retry"
            icon="refresh"
            kind="plain"
            compact
            onPress={() => CrossDrop.retryQueued(item.id)}
            accessibilityLabel={`Retry sending ${title} to ${item.deviceName}`}
          />
        ) : null}
        <Button
          title={item.status === 'sending' ? 'Stop' : 'Cancel'}
          kind="plain"
          compact
          onPress={() => CrossDrop.cancelQueued(item.id)}
          accessibilityLabel={`Cancel sending ${title} to ${item.deviceName}`}
        />
      </View>
    </View>
  );
}

const removeItem = (item: PocketItem) =>
  Alert.alert(
    `Remove ${item.name}?`,
    'Remove it from the Pocket only, or also delete the saved file from this phone.',
    [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Remove from Pocket',
        onPress: () => {
          CrossDrop.removePocketItem(item.id, false).catch(() => false);
        },
      },
      {
        text: 'Delete file',
        style: 'destructive',
        onPress: async () => {
          const ok = await CrossDrop.removePocketItem(item.id, true).catch(
            () => false,
          );
          if (!ok) {
            Alert.alert(
              'Couldn’t delete the file',
              'It may have been moved or deleted already, or another app owns it now. You can remove it in the Files app.',
            );
          }
        },
      },
    ],
  );

const shareItem = async (item: PocketItem) => {
  const ok = await CrossDrop.sharePocketItem(item.id).catch(() => false);
  if (!ok) {
    Alert.alert(
      'Couldn’t share it',
      'The file is no longer where CrossDrop saved it.',
    );
  }
};

/** A recently received file: tap to open; share it on, or remove it. */
export function PocketRow({ item, now }: { item: PocketItem; now: number }) {
  const t = useTheme();
  const meta = `From ${item.from} · ${formatBytes(item.size)} · ${relativeTime(
    item.receivedAt,
    now,
  )}`;
  const expiry =
    item.deleteAt !== null ? deleteLabel(item.deleteAt, now, 'incoming') : null;
  return (
    <View style={styles.row}>
      <Pressable
        onPress={() => CrossDrop.openPocketItem(item.id)}
        accessibilityRole="button"
        accessibilityLabel={`${item.name}. ${meta}${
          expiry ? `. ${expiry}` : ''
        }`}
        accessibilityHint="Opens the file"
        android_ripple={{ color: t.accentSoft }}
        style={styles.main}
      >
        <View style={styles.thumb}>
          <Icon name={iconForMime(item.mime)} size={20} color={t.link} />
        </View>
        <View style={styles.text}>
          <Text variant="callout" numberOfLines={1}>
            {item.name}
          </Text>
          <Text variant="footnote" tone="secondary" numberOfLines={1}>
            {meta}
          </Text>
          {expiry ? (
            <View style={styles.expiry}>
              <Icon name="clock" size={13} color={t.warning} />
              <Text variant="footnote" tone="warning" numberOfLines={1}>
                {expiry}
              </Text>
            </View>
          ) : null}
        </View>
      </Pressable>
      <Pressable
        onPress={() => shareItem(item)}
        accessibilityRole="button"
        accessibilityLabel={`Share ${item.name}`}
        android_ripple={{ color: t.accentSoft, borderless: true }}
        style={styles.iconButton}
      >
        <Icon name="share" size={19} color={t.link} />
      </Pressable>
      <Pressable
        onPress={() => removeItem(item)}
        accessibilityRole="button"
        accessibilityLabel={`Remove ${item.name}`}
        android_ripple={{ color: t.dangerSoft, borderless: true }}
        style={styles.iconButton}
      >
        <Icon name="trash" size={19} color={t.textSecondary} />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xxs,
    minHeight: minTouch + 12,
    paddingHorizontal: spacing.xxs,
  },
  main: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.xxs,
    minHeight: minTouch,
  },
  bubble: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  thumb: {
    width: 40,
    height: 40,
    borderRadius: 12,
    backgroundColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1, minWidth: 0 },
  expiry: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  actions: { alignItems: 'flex-end' },
  iconButton: {
    width: minTouch,
    height: minTouch,
    borderRadius: minTouch / 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
