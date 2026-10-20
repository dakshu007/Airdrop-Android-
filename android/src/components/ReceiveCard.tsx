import React from 'react';
import { Alert, StyleSheet, Switch, View } from 'react-native';
import { friendlyError } from '../copy';
import { formatClock } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { Snapshot } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import { GlassCard } from './GlassCard';
import { IconBubble } from './IconBubble';
import { Text } from './Text';

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

/** Receive-availability toggle. */
export function ReceiveCard({ snapshot }: { snapshot: Snapshot }) {
  const t = useTheme();
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
    detail =
      'Visible to nearby devices while on. Turns off after 10 minutes to save battery.';
  } else if (receiving.autoOffAt !== null) {
    detail = `Visible to nearby devices as “${
      local.name
    }”. Turns off at ${formatClock(receiving.autoOffAt)} to save battery.`;
  } else {
    detail = `Visible to nearby devices as “${local.name}”. Stays on while a transfer is running.`;
  }
  const error = receiving.error ? friendlyError(receiving.error) : null;

  return (
    <GlassCard tint={receiving.enabled ? t.accentSoft : undefined}>
      <View style={styles.row}>
        <IconBubble name="download" size={44} />
        <View style={styles.text}>
          <Text variant="headline">Receiving</Text>
          <Text variant="footnote" tone="secondary">
            {detail}
          </Text>
        </View>
        <Switch
          value={receiving.enabled}
          onValueChange={toggle}
          accessibilityLabel="Receiving"
          accessibilityHint={detail}
          trackColor={{ false: t.track, true: t.accent }}
          thumbColor="#FFFFFF"
          style={styles.switch}
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
  switch: { minHeight: 48 },
  error: { marginTop: spacing.sm, gap: 2 },
});
