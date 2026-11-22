import React from 'react';
import { StyleSheet, View } from 'react-native';
import { formatBytes } from '../format';
import type { NearbyDevice, QueueStorage } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import { Button } from './Button';
import { Icon } from './Icon';
import { IconBubble } from './IconBubble';
import { Ripple } from './Ripple';
import { Sheet } from './Sheet';
import { Text } from './Text';

export type QueueOfferReason =
  /** Paired, but discovery hasn't found it. */
  | 'notSeen'
  /** A send was just tried and the device couldn't be reached. */
  | 'unreachable';

interface Props {
  device: NearbyDevice;
  reason: QueueOfferReason;
  /** True once the device shows up nearby while the sheet is open. */
  foundNow: boolean;
  /** What would be sent, e.g. "3 files" or "the link"; null when files are chosen next. */
  what: string | null;
  storage: QueueStorage;
  busy: boolean;
  /** Set after queueing worked: the sheet shows the confirmation. */
  queued: boolean;
  error: string | null;
  onQueue: () => void;
  onTryNow: () => void;
  onClose: () => void;
}

/**
 * Offered when a paired device isn't around: keep the files and send them by
 * themselves the next time it's found (no background scanning — the engine
 * looks when Wi‑Fi comes back, at app start and when the device appears).
 */
export function QueueOfferSheet({
  device,
  reason,
  foundNow,
  what,
  storage,
  busy,
  queued,
  error,
  onQueue,
  onTryNow,
  onClose,
}: Props) {
  const t = useTheme();
  const subject = what ?? 'files';

  if (queued) {
    return (
      <Sheet
        visible
        onRequestClose={onClose}
        accessibilityLabel="Waiting to send"
      >
        <View style={styles.center}>
          <Ripple size={150} once>
            <IconBubble name="clock" size={64} />
          </Ripple>
          <Text
            variant="title"
            center
            accessibilityRole="header"
            accessibilityLiveRegion="polite"
          >
            Waiting for {device.name}
          </Text>
          <Text variant="callout" tone="secondary" center>
            It goes by itself the next time this phone finds {device.name}: when
            you open CrossDrop, when Wi‑Fi reconnects, or while Nearby is open.
            No scanning in the background. Follow or cancel it in Activity.
          </Text>
        </View>
        <Button title="Done" large onPress={onClose} />
      </Sheet>
    );
  }

  const title = foundNow
    ? `${device.name} is here`
    : reason === 'unreachable'
    ? `Couldn’t reach ${device.name}`
    : `${device.name} isn’t nearby`;
  const detail = foundNow
    ? 'It just showed up. Send now, or still keep it for later.'
    : reason === 'unreachable'
    ? 'It may be asleep, on another Wi‑Fi, or not receiving. CrossDrop can hold on to this and send it when it’s back.'
    : 'It’s paired but hasn’t shown up on this Wi‑Fi. Send it when it’s nearby, or try its last address now.';

  return (
    <Sheet
      visible
      onRequestClose={onClose}
      accessibilityLabel={`Send to ${device.name} later`}
    >
      <View style={styles.head}>
        <IconBubble
          name={device.platform === 'macos' ? 'laptop' : 'phone'}
          size={52}
        />
        <View style={styles.flex}>
          <Text variant="title" accessibilityRole="header">
            {title}
          </Text>
        </View>
      </View>
      <Text variant="callout" tone="secondary" accessibilityLiveRegion="polite">
        {detail}
      </Text>

      <View style={[styles.note, { backgroundColor: t.inset }]}>
        <Icon name="shieldCheck" size={18} color={t.link} />
        <Text variant="footnote" tone="secondary" style={styles.flex}>
          Stays on this phone until then. Files you shared from another app are
          kept in CrossDrop ({formatBytes(storage.usedBytes)} of{' '}
          {formatBytes(storage.limitBytes)} used); files you picked are read
          from where they are.
        </Text>
      </View>

      {error ? (
        <Text variant="footnote" tone="danger" accessibilityLiveRegion="polite">
          {error}
        </Text>
      ) : null}

      {foundNow ? (
        <>
          <Button
            title={`Send ${subject} now`}
            icon="send"
            large
            loading={busy}
            onPress={onTryNow}
          />
          <Button
            title="Send when nearby"
            icon="clock"
            kind="secondary"
            disabled={busy}
            onPress={onQueue}
          />
        </>
      ) : (
        <>
          <Button
            title="Send when nearby"
            icon="clock"
            large
            loading={busy}
            onPress={onQueue}
            accessibilityHint={`Sends ${subject} to ${device.name} by itself when it is found`}
          />
          {reason === 'notSeen' ? (
            <Button
              title="Try now anyway"
              kind="secondary"
              disabled={busy}
              onPress={onTryNow}
            />
          ) : null}
        </>
      )}
      <Button
        title="Cancel"
        kind="plain"
        disabled={busy}
        onPress={onClose}
        accessibilityLabel="Cancel sending later"
      />
    </Sheet>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  head: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  center: { alignItems: 'center', gap: spacing.xs },
  note: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-start',
    borderRadius: 18,
    padding: spacing.sm,
  },
});
