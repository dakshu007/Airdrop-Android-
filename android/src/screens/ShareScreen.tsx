import React from 'react';
import { StyleSheet, View } from 'react-native';
import { RoundButton } from '../components/Chips';
import { Logo } from '../components/Logo';
import { Text } from '../components/Text';
import { pluralFiles } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useSendFiles } from '../state/useSendFiles';
import { spacing } from '../theme/tokens';
import { NearbyView, Tray } from './NearbyScreen';

/** Shown when files arrive from the Android share sheet: pick a device and they go. */
export function ShareScreen() {
  const snapshot = useSnapshot();
  const files = snapshot.shared;
  const { send, busy } = useSendFiles();

  const onSelect = async (device: NearbyDevice) => {
    if (await send(device, files)) {
      CrossDrop.clearSharedFiles();
    }
  };

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
      readyTitle={`Send ${pluralFiles(files.length)}`}
      onSelect={onSelect}
      busy={busy}
      actionHint={device =>
        `Sends ${pluralFiles(files.length)} to ${device.name}`
      }
      footer={
        <View style={styles.group}>
          <Tray files={files} />
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
