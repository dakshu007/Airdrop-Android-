import React, { useCallback } from 'react';
import { StyleSheet, View } from 'react-native';
import { RoundButton } from '../components/Chips';
import { Logo } from '../components/Logo';
import { Text } from '../components/Text';
import { pluralFiles } from '../format';
import * as CrossDrop from '../native/crossdrop';
import { useCrossDrop, useSnapshot } from '../state/CrossDropProvider';
import { useSendFlow } from '../state/useSendFlow';
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
  const { autoDelete, setAutoDelete } = useCrossDrop();
  const resolveFiles = useCallback(async () => files, [files]);
  const flow = useSendFlow({
    resolveFiles,
    count: files.length,
    text,
    onDone: CrossDrop.clearSharedFiles,
  });
  const busy = flow.busy;
  const onSelect = flow.select;
  const onSelectMany = flow.selectMany;

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
    <View style={styles.flex}>
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
            {text ? (
              <TextTray text={text} />
            ) : (
              <Tray
                files={files}
                autoDelete={autoDelete}
                onAutoDelete={setAutoDelete}
              />
            )}
            <Text variant="footnote" tone="secondary" center>
              Tap a device to send
            </Text>
          </View>
        }
        bottomSpace={spacing.xl}
      />
      {flow.element}
    </View>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  brand: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  spacer: { width: 44 },
  group: { gap: 10 },
});
