import React, { useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { Drip } from '../components/Drip';
import { Sheet } from '../components/Sheet';
import { Text } from '../components/Text';
import * as CrossDrop from '../native/crossdrop';
import { setNotificationPromptListener } from '../state/useReceiving';
import { spacing } from '../theme/tokens';

/** Why CrossDrop wants notifications, before Android's own permission dialog. */
export function NotificationPrompt() {
  const [open, setOpen] = useState(false);
  const next = useRef<(() => void) | null>(null);

  useEffect(() => {
    setNotificationPromptListener(then => {
      next.current = then;
      setOpen(true);
    });
    return () => setNotificationPromptListener(null);
  }, []);

  const finish = (ask: boolean) => {
    setOpen(false);
    const then = next.current ?? (() => undefined);
    next.current = null;
    if (ask) {
      CrossDrop.requestNotificationPermission()
        .catch(() => undefined)
        .finally(then);
    } else {
      then();
    }
  };

  if (!open) return null;
  return (
    <Sheet
      visible
      onRequestClose={() => finish(false)}
      accessibilityLabel="Allow notifications"
    >
      <View style={styles.head}>
        <Drip pose="incoming" size={150} motion="bob" />
        <Text variant="title" center accessibilityRole="header">
          Know when files arrive
        </Text>
        <Text variant="callout" tone="secondary" center>
          CrossDrop shows a notification while it’s receiving and when files
          arrive. File names stay hidden on the lock screen.
        </Text>
      </View>
      <Button title="Continue" large onPress={() => finish(true)} />
      <Button title="Not now" kind="plain" onPress={() => finish(false)} />
    </Sheet>
  );
}

const styles = StyleSheet.create({
  head: { alignItems: 'center', gap: spacing.xs },
});
