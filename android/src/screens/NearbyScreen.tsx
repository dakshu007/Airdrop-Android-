import React from 'react';
import { StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { FileRow } from '../components/FileRow';
import { GlassCard } from '../components/GlassCard';
import { NearbyDeviceList } from '../components/NearbyDeviceList';
import { ReceiveCard } from '../components/ReceiveCard';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { formatBytes, pluralFiles, sumSizes } from '../format';
import type { NearbyDevice } from '../native/types';
import { useCrossDrop, useSnapshot } from '../state/CrossDropProvider';
import { pickFilesSafely, useSendFiles } from '../state/useSendFiles';
import { spacing } from '../theme/tokens';

const TRAY_PREVIEW = 4;

export function NearbyScreen() {
  const snapshot = useSnapshot();
  const { selection, addToSelection, removeFromSelection, clearSelection } =
    useCrossDrop();
  const { send, busy } = useSendFiles();
  const { total, unknown } = sumSizes(selection);

  const choose = async () => addToSelection(await pickFilesSafely());

  const onSelectDevice = async (device: NearbyDevice) => {
    let files = selection;
    if (files.length === 0) {
      files = await pickFilesSafely();
      if (files.length === 0) {
        return;
      }
    }
    if (await send(device, files)) {
      clearSelection();
    }
  };

  const sizeText = `${formatBytes(total)}${unknown ? '+' : ''}`;

  return (
    <Screen title="CrossDrop" subtitle={`This phone: ${snapshot.local.name}`}>
      <ReceiveCard snapshot={snapshot} />

      <SectionHeader
        title="Send"
        trailing={
          selection.length > 0 ? (
            <Button
              title="Clear"
              kind="plain"
              compact
              onPress={clearSelection}
              accessibilityLabel="Clear selected files"
            />
          ) : null
        }
      />
      {selection.length === 0 ? (
        <GlassCard>
          <Text variant="callout" tone="secondary" style={styles.lead}>
            Choose files, then tap a nearby device. You can also share straight
            from any app — pick CrossDrop in the share sheet.
          </Text>
          <Button title="Choose files" icon="plus" onPress={choose} />
        </GlassCard>
      ) : (
        <GlassCard>
          <Text variant="headline">
            {pluralFiles(selection.length)} · {sizeText}
          </Text>
          <Text variant="footnote" tone="secondary" style={styles.lead}>
            Tap a device below to send.
          </Text>
          {selection.slice(0, TRAY_PREVIEW).map(f => (
            <FileRow
              key={f.uri}
              name={f.name}
              size={f.size}
              mime={f.mime}
              onRemove={() => removeFromSelection(f.uri)}
            />
          ))}
          {selection.length > TRAY_PREVIEW ? (
            <Text variant="footnote" tone="tertiary" style={styles.more}>
              and {selection.length - TRAY_PREVIEW} more
            </Text>
          ) : null}
          <View style={styles.trayActions}>
            <Button
              title="Add more"
              kind="secondary"
              compact
              icon="plus"
              onPress={choose}
            />
          </View>
        </GlassCard>
      )}

      <SectionHeader title="Nearby" />
      <NearbyDeviceList
        snapshot={snapshot}
        busy={busy}
        onSelect={onSelectDevice}
        actionHint={device =>
          selection.length > 0
            ? `Sends ${pluralFiles(selection.length)} to ${device.name}`
            : `Choose files to send to ${device.name}`
        }
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  lead: { marginTop: spacing.xxs, marginBottom: spacing.md },
  more: { marginTop: spacing.xs },
  trayActions: { flexDirection: 'row', marginTop: spacing.sm },
});
