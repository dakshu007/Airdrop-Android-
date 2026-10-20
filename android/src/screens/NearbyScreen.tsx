import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { FileRow } from '../components/FileRow';
import { Frost } from '../components/Frost';
import { Icon } from '../components/Icon';
import { NearbyDeviceList } from '../components/NearbyDeviceList';
import { ReceiveCard } from '../components/ReceiveCard';
import { Screen } from '../components/Screen';
import { Text } from '../components/Text';
import { formatBytes, pluralFiles, sumSizes } from '../format';
import type { NearbyDevice } from '../native/types';
import { useNavigation } from '../navigation/NavigationContext';
import { useCrossDrop, useSnapshot } from '../state/CrossDropProvider';
import { pickFilesSafely, useSendFiles } from '../state/useSendFiles';
import { minTouch, spacing } from '../theme/tokens';

const TRAY_PREVIEW = 3;

export function NearbyScreen() {
  const snapshot = useSnapshot();
  const { navigate } = useNavigation();
  const { selection, addToSelection, removeFromSelection, clearSelection } = useCrossDrop();
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

  const footer =
    selection.length === 0 ? (
      <View style={styles.choose}>
        <Button title="Choose files" icon="plus" onPress={choose} />
        <Text variant="footnote" tone="tertiary" center>
          or pick CrossDrop in any app’s share menu
        </Text>
      </View>
    ) : (
      <View>
        <View style={styles.trayHead}>
          <Text variant="headline">
            {pluralFiles(selection.length)} · {sizeText}
          </Text>
          <View style={styles.trayActions}>
            <Button title="Add" kind="secondary" compact icon="plus" onPress={choose} />
            <Button
              title="Clear"
              kind="plain"
              compact
              onPress={clearSelection}
              accessibilityLabel="Clear selected files"
            />
          </View>
        </View>
        {selection.slice(0, TRAY_PREVIEW).map(f => (
          <FileRow key={f.uri} name={f.name} size={f.size} mime={f.mime} onRemove={() => removeFromSelection(f.uri)} />
        ))}
        {selection.length > TRAY_PREVIEW ? (
          <Text variant="footnote" tone="tertiary" style={styles.more}>
            and {selection.length - TRAY_PREVIEW} more
          </Text>
        ) : null}
        <Text variant="footnote" tone="secondary" center style={styles.more}>
          Tap a device to send
        </Text>
      </View>
    );

  const settingsButton = (
    <Pressable
      onPress={() => navigate('settings')}
      accessibilityRole="button"
      accessibilityLabel="Settings"
      style={styles.round}
    >
      <Frost radius={minTouch / 2} tint="rgba(255,255,255,0.16)" />
      <Icon name="settings" size={22} color="#FFFFFF" />
    </Pressable>
  );

  return (
    <Screen
      title="CrossDrop"
      subtitle={`${snapshot.local.name} · ${snapshot.receiving.enabled ? 'visible nearby' : 'not visible'}`}
      trailing={settingsButton}
    >
      <ReceiveCard snapshot={snapshot} />
      <View style={styles.gap} />
      <NearbyDeviceList
        snapshot={snapshot}
        busy={busy}
        onSelect={onSelectDevice}
        heroFooter={footer}
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
  gap: { height: spacing.md },
  choose: { gap: spacing.sm },
  trayHead: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: spacing.xs, gap: spacing.xs },
  trayActions: { flexDirection: 'row', alignItems: 'center', gap: spacing.xxs },
  more: { marginTop: spacing.xs },
  round: {
    width: minTouch,
    height: minTouch,
    borderRadius: minTouch / 2,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
});
