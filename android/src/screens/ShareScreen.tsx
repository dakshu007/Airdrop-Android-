import React, { useState } from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { RoundButton } from '../components/Chips';
import { Logo } from '../components/Logo';
import { Text } from '../components/Text';
import { pluralFiles } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useSendFiles } from '../state/useSendFiles';
import { spacing } from '../theme/tokens';
import { NearbyView, TextTray, Tray } from './NearbyScreen';

/**
 * Shown when files, a link or text arrive from the Android share sheet (or the
 * clipboard tile): pick a device — or several — and they go.
 */
export function ShareScreen() {
  const snapshot = useSnapshot();
  const files = snapshot.shared;
  const text = snapshot.sharedText;
  const { send, busy: sendingFiles } = useSendFiles();
  const [sendingText, setSendingText] = useState(false);
  const busy = sendingFiles || sendingText;

  const sendTo = async (device: NearbyDevice): Promise<boolean> => {
    if (!text) return send(device, files);
    setSendingText(true);
    try {
      await CrossDrop.sendSharedText(device.deviceId);
      return true;
    } catch (e) {
      Alert.alert(
        `Couldn’t send to ${device.name}`,
        e instanceof Error && e.message ? e.message : 'Try again.',
      );
      return false;
    } finally {
      setSendingText(false);
    }
  };

  const onSelect = async (device: NearbyDevice) => {
    if (await sendTo(device)) {
      CrossDrop.clearSharedFiles();
    }
  };

  const onSelectMany = async (devices: NearbyDevice[]) => {
    let sent = 0;
    for (const device of devices) {
      if (await sendTo(device)) sent += 1;
    }
    if (sent > 0) CrossDrop.clearSharedFiles();
  };

  const what = text
    ? text.kind === 'link'
      ? 'link'
      : 'text'
    : pluralFiles(files.length);

  const header = (
    <View style={styles.header}>
      <RoundButton
        icon="x"
        label="Cancel sharing"
        onPress={() => CrossDrop.clearSharedFiles()}
      />
      <View style={styles.brand}>
        <Logo size={24} />
        <Text variant="headline">CrossDrop</Text>
      </View>
      <View style={styles.spacer} />
    </View>
  );

  return (
    <NearbyView
      snapshot={snapshot}
      files={files}
      header={header}
      readyTitle={`Send ${text ? `this ${what}` : what}`}
      onSelect={onSelect}
      onSelectMany={onSelectMany}
      busy={busy}
      actionHint={device =>
        `Sends ${text ? `the ${what}` : what} to ${device.name}`
      }
      footer={
        <View style={styles.group}>
          {text ? <TextTray text={text} /> : <Tray files={files} />}
          <Text variant="footnote" tone="secondary" center>
            Tap a device to send
          </Text>
        </View>
      }
      bottomSpace={spacing.xl}
    />
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  brand: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  spacer: { width: 44 },
  group: { gap: 10 },
});
