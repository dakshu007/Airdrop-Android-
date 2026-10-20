import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { FileRow } from '../components/FileRow';
import { GlassCard } from '../components/GlassCard';
import { Icon } from '../components/Icon';
import { NearbyDeviceList } from '../components/NearbyDeviceList';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { formatBytes, pluralFiles, sumSizes } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useSendFiles } from '../state/useSendFiles';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, spacing } from '../theme/tokens';

const PREVIEW = 5;

/** Shown when files arrive from the Android share sheet. */
export function ShareScreen() {
  const t = useTheme();
  const snapshot = useSnapshot();
  const files = snapshot.shared;
  const { send, busy } = useSendFiles();
  const { total, unknown } = sumSizes(files);
  const sizeText = `${formatBytes(total)}${unknown ? '+' : ''}`;

  const onSelect = async (device: NearbyDevice) => {
    if (await send(device, files)) {
      CrossDrop.clearSharedFiles();
    }
  };

  const close = (
    <Pressable
      onPress={() => CrossDrop.clearSharedFiles()}
      accessibilityRole="button"
      accessibilityLabel="Cancel sharing"
      style={[
        styles.close,
        { backgroundColor: t.glassFill, borderColor: t.glassBorder },
      ]}
    >
      <Icon name="x" size={22} color={t.textPrimary} />
    </Pressable>
  );

  return (
    <Screen
      title={`Send ${pluralFiles(files.length)}`}
      subtitle={`${sizeText} · choose a device`}
      trailing={close}
      bottomSpace={spacing.xxl}
    >
      <GlassCard
        accessibilityLabel={`${pluralFiles(files.length)}, ${sizeText}`}
      >
        {files.slice(0, PREVIEW).map(f => (
          <FileRow key={f.uri} name={f.name} size={f.size} mime={f.mime} />
        ))}
        {files.length > PREVIEW ? (
          <Text variant="footnote" tone="tertiary" style={styles.more}>
            and {files.length - PREVIEW} more
          </Text>
        ) : null}
      </GlassCard>
      <SectionHeader title="Nearby" />
      <View>
        <NearbyDeviceList
          snapshot={snapshot}
          busy={busy}
          onSelect={onSelect}
          actionHint={device =>
            `Sends ${pluralFiles(files.length)} to ${device.name}`
          }
        />
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  close: {
    width: minTouch,
    height: minTouch,
    borderRadius: minTouch / 2,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  more: { marginTop: spacing.xs },
});
