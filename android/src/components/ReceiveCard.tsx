import React from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { friendlyError } from '../copy';
import { formatClock } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { Snapshot } from '../native/types';
import { radii, spacing } from '../theme/tokens';
import { GlassCard } from './GlassCard';
import { IconBubble } from './IconBubble';
import { Text } from './Text';
import { Toggle } from './Toggle';

function askForNotificationsThen(next: () => void) {
  Alert.alert(
    'Allow notifications?',
    'CrossDrop shows a notification while it is receiving and when files arrive. File names stay hidden on the lock screen.',
    [
      { text: 'Not now', style: 'cancel', onPress: next },
      {
        text: 'Continue',
        onPress: () => {
          CrossDrop.requestNotificationPermission()
            .catch(() => undefined)
            .finally(next);
        },
      },
    ],
    { cancelable: false },
  );
}

/** Receive-availability control, styled like a control-centre tile. */
export function ReceiveCard({ snapshot }: { snapshot: Snapshot }) {
  const { receiving, local } = snapshot;
  const toggle = (value: boolean) => {
    if (value && snapshot.notificationPermission === 'undetermined') {
      askForNotificationsThen(() => CrossDrop.setReceiving(true));
      return;
    }
    CrossDrop.setReceiving(value);
  };

  let detail: string;
  if (!receiving.enabled) {
    detail = 'Off · nearby Macs can’t see this phone';
  } else if (receiving.autoOffAt !== null) {
    detail = `Visible as “${local.name}” · until ${formatClock(receiving.autoOffAt)}`;
  } else {
    detail = `Visible as “${local.name}” · on while receiving`;
  }
  const hint = receiving.enabled
    ? 'Turns receiving off'
    : 'Lets nearby devices send to this phone. Turns off by itself after 10 minutes.';
  const error = receiving.error ? friendlyError(receiving.error) : null;

  return (
    <GlassCard radius={radii.lg} padding={spacing.sm + 2}>
      <View style={styles.row}>
        <IconBubble
          name="download"
          size={48}
          background={receiving.enabled ? 'rgba(76,217,128,0.45)' : undefined}
        />
        <View style={styles.text}>
          <Text variant="headline">Receiving</Text>
          <Text variant="footnote" tone="secondary" numberOfLines={2}>
            {detail}
          </Text>
        </View>
        <Toggle
          value={receiving.enabled}
          onValueChange={toggle}
          accessibilityLabel="Receiving"
          accessibilityHint={hint}
        />
      </View>
      {error ? (
        <View style={styles.error}>
          <Text variant="subhead" tone="danger">
            {error.title}
          </Text>
          <Text variant="footnote" tone="secondary">
            {error.detail}
          </Text>
        </View>
      ) : null}
    </GlassCard>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  text: { flex: 1, gap: 2 },
  error: { marginTop: spacing.sm, gap: 2, paddingHorizontal: spacing.xxs },
});
