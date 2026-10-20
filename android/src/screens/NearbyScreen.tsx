import React, { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Button } from '../components/Button';
import { RoundButton } from '../components/Chips';
import { DeviceRow } from '../components/DeviceRow';
import { DripStage } from '../components/DripStage';
import { FileRow } from '../components/FileRow';
import { Frost } from '../components/Frost';
import { Logo } from '../components/Logo';
import { TAB_BAR_SPACE } from '../components/Screen';
import { Sheet } from '../components/Sheet';
import { Text } from '../components/Text';
import { friendlyError } from '../copy';
import { formatBytes, formatClock, pluralFiles, sumSizes } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice, SharedFile, Snapshot } from '../native/types';
import { useNavigation } from '../navigation/NavigationContext';
import { useCrossDrop, useSnapshot } from '../state/CrossDropProvider';
import { useReceivingToggle } from '../state/useReceiving';
import { pickFilesSafely, useSendFiles } from '../state/useSendFiles';
import { useTheme } from '../theme/ThemeProvider';
import { green, spacing } from '../theme/tokens';

const TRAY_PREVIEW = 2;

/** Which of Drip's moods the Nearby screen is in. */
export type NearbyMode =
  | 'noWifi'
  | 'discoveryError'
  | 'devices'
  | 'napping'
  | 'searching';

export function nearbyMode(snapshot: Snapshot): NearbyMode {
  if (!snapshot.network.localNetwork) return 'noWifi';
  if (snapshot.discovery.error) return 'discoveryError';
  if (snapshot.nearby.length > 0) return 'devices';
  if (!snapshot.receiving.enabled) return 'napping';
  return 'searching';
}

/** The mini switch inside the receiving pill. */
function MiniSwitch({ on }: { on: boolean }) {
  return (
    <View
      style={[
        styles.switch,
        {
          backgroundColor: on ? green : '#C4D6CA',
          alignItems: on ? 'flex-end' : 'flex-start',
        },
      ]}
    >
      <View style={styles.knob} />
    </View>
  );
}

function ReceivingPill({ snapshot }: { snapshot: Snapshot }) {
  const toggle = useReceivingToggle(snapshot);
  const { receiving, local } = snapshot;
  const label = receiving.enabled
    ? receiving.autoOffAt !== null
      ? `Receiving · until ${formatClock(receiving.autoOffAt)}`
      : `Receiving · visible as ${local.name}`
    : 'Receiving off';
  return (
    <Pressable
      onPress={() => toggle(!receiving.enabled)}
      accessibilityRole="switch"
      accessibilityLabel="Receiving"
      accessibilityState={{ checked: receiving.enabled }}
      accessibilityHint={
        receiving.enabled
          ? `Visible to nearby devices as ${local.name}. Double tap to turn off.`
          : 'Lets nearby devices send to this phone. Turns off by itself after 10 minutes.'
      }
      style={styles.pill}
    >
      <Frost radius={999} />
      <Text variant="subhead" style={styles.pillText} numberOfLines={1}>
        {label}
      </Text>
      <MiniSwitch on={receiving.enabled} />
    </Pressable>
  );
}

function Tips() {
  const tips = [
    'Open CrossDrop on your Mac and turn on Receiving',
    'Use the same Wi‑Fi on both — guest networks often block this',
  ];
  const t = useTheme();
  return (
    <View style={styles.tips}>
      <Frost radius={22} />
      {tips.map((tip, i) => (
        <View key={tip}>
          {i > 0 ? (
            <View style={[styles.hairline, { backgroundColor: t.hairline }]} />
          ) : null}
          <View style={styles.tip}>
            <View style={styles.tipNumber}>
              <Text variant="caption" tone="onAccent">
                {i + 1}
              </Text>
            </View>
            <Text variant="callout" style={styles.flex}>
              {tip}
            </Text>
          </View>
        </View>
      ))}
    </View>
  );
}

function Tray({
  files,
  onAdd,
  onClear,
  onRemove,
}: {
  files: SharedFile[];
  onAdd?: () => void;
  onClear?: () => void;
  onRemove?: (uri: string) => void;
}) {
  const { total, unknown } = sumSizes(files);
  return (
    <View style={styles.tray}>
      <Frost radius={22} />
      <View style={styles.trayHead}>
        <Text variant="headline" style={styles.flex} numberOfLines={1}>
          {pluralFiles(files.length)} ·{' '}
          {unknown && total === 0
            ? 'size unknown'
            : `${formatBytes(total)}${unknown ? '+' : ''}`}
        </Text>
        {onAdd ? (
          <Button
            title="Add"
            kind="plain"
            compact
            icon="plus"
            onPress={onAdd}
          />
        ) : null}
        {onClear ? (
          <Button
            title="Clear"
            kind="plain"
            compact
            onPress={onClear}
            accessibilityLabel="Clear selected files"
          />
        ) : null}
      </View>
      {files.slice(0, TRAY_PREVIEW).map(f => (
        <FileRow
          key={f.uri}
          name={f.name}
          size={f.size}
          mime={f.mime}
          onRemove={onRemove ? () => onRemove(f.uri) : undefined}
        />
      ))}
      {files.length > TRAY_PREVIEW ? (
        <Text variant="footnote" tone="secondary">
          and {files.length - TRAY_PREVIEW} more
        </Text>
      ) : null}
    </View>
  );
}

interface NearbyViewProps {
  snapshot: Snapshot;
  /** Files waiting to be sent: chosen here, or handed over by the share sheet. */
  files: SharedFile[];
  header: React.ReactNode;
  /** Title when devices are around (e.g. "Ready to send" or "Send 3 files"). */
  readyTitle: string;
  onSelect: (device: NearbyDevice) => void;
  busy: boolean;
  actionHint: (device: NearbyDevice) => string;
  /** The main action when devices are around (Choose files) or files are waiting (tray). */
  footer: React.ReactNode;
  bottomSpace: number;
}

/** Drip's stage: shared by the Nearby tab and the share-sheet flow. */
export function NearbyView({
  snapshot,
  files,
  header,
  readyTitle,
  onSelect,
  busy,
  actionHint,
  footer,
  bottomSpace,
}: NearbyViewProps) {
  const insets = useSafeAreaInsets();
  const toggleReceiving = useReceivingToggle(snapshot);
  const [showAll, setShowAll] = useState(false);
  const mode = nearbyMode(snapshot);
  const count = snapshot.nearby.length;

  let title: string;
  let subtitle: string;
  let stage: React.ReactNode;
  let action: React.ReactNode = footer;

  switch (mode) {
    case 'noWifi':
      title = 'No Wi‑Fi';
      subtitle =
        'CrossDrop needs this phone and your Mac on the same Wi‑Fi. Mobile data won’t work for this.';
      stage = <DripStage pose="nowifi" motion="bob" />;
      action = (
        <View style={styles.footerGroup}>
          <Button
            title="Open Wi‑Fi settings"
            icon="wifi"
            large
            onPress={() => CrossDrop.openWifiSettings()}
          />
          <Text variant="footnote" tone="secondary" center>
            Drip will start looking again once you’re connected
          </Text>
        </View>
      );
      break;
    case 'discoveryError': {
      const e = friendlyError(snapshot.discovery.error);
      title = e.title;
      subtitle = e.detail;
      stage = <DripStage pose="searching" motion="none" />;
      action = (
        <Button
          title="Try again"
          icon="refresh"
          large
          onPress={() => {
            CrossDrop.stopDiscovery();
            CrossDrop.startDiscovery();
          }}
        />
      );
      break;
    }
    case 'devices':
      title = readyTitle;
      subtitle = `${count} ${
        count === 1 ? 'device' : 'devices'
      } nearby. Tap one to send.`;
      stage = (
        <DripStage
          pose="nearby"
          motion="bob"
          rings="halo"
          devices={snapshot.nearby}
          busy={busy}
          onSelect={onSelect}
          actionHint={actionHint}
          onShowAll={() => setShowAll(true)}
        />
      );
      break;
    case 'napping':
      title = 'Drip is napping';
      subtitle =
        'Receiving is off, so nearby Macs can’t see this phone. Macs you can send to still show up here.';
      stage = <DripStage pose="sleepy" motion="breathe" />;
      action = (
        <View style={styles.footerGroup}>
          {files.length > 0 ? footer : null}
          <Button
            title="Turn on Receiving"
            icon="download"
            large
            onPress={() => toggleReceiving(true)}
          />
          <Text variant="footnote" tone="secondary" center>
            Turns off again after 10 minutes
          </Text>
        </View>
      );
      break;
    case 'searching':
      title = 'No devices yet';
      subtitle =
        'Drip is still looking. A Mac shows up here as soon as it’s ready.';
      stage = <DripStage pose="searching" motion="scan" rings="ping" />;
      action = (
        <View style={styles.footerGroup}>
          {files.length > 0 ? footer : <Tips />}
        </View>
      );
      break;
  }

  return (
    <View style={styles.flex}>
      <ScrollView
        style={styles.flex}
        contentContainerStyle={[
          styles.content,
          {
            paddingTop: insets.top + spacing.sm,
            paddingBottom: insets.bottom + bottomSpace,
            paddingLeft: insets.left + spacing.xl,
            paddingRight: insets.right + spacing.xl,
          },
        ]}
        showsVerticalScrollIndicator={false}
        bounces={false}
      >
        {header}
        {mode === 'noWifi' ? null : <ReceivingPill snapshot={snapshot} />}
        {snapshot.receiving.error ? (
          <Text variant="footnote" tone="danger" center>
            {friendlyError(snapshot.receiving.error).title}
          </Text>
        ) : null}
        <View style={styles.titles}>
          <Text variant="largeTitle" center accessibilityRole="header">
            {title}
          </Text>
          <Text
            variant="body"
            tone="secondary"
            center
            accessibilityLiveRegion="polite"
          >
            {subtitle}
          </Text>
        </View>
        {stage}
        <View style={styles.footer}>{action}</View>
      </ScrollView>
      {showAll ? (
        <Sheet
          visible
          onRequestClose={() => setShowAll(false)}
          accessibilityLabel="Nearby devices"
        >
          <Text variant="title" accessibilityRole="header">
            Nearby
          </Text>
          {snapshot.nearby.map(device => (
            <DeviceRow
              key={device.deviceId}
              device={device}
              disabled={busy}
              actionHint={actionHint(device)}
              onPress={() => {
                setShowAll(false);
                onSelect(device);
              }}
            />
          ))}
        </Sheet>
      ) : null}
    </View>
  );
}

export function NearbyScreen() {
  const snapshot = useSnapshot();
  const { navigate } = useNavigation();
  const { selection, addToSelection, removeFromSelection, clearSelection } =
    useCrossDrop();
  const { send, busy } = useSendFiles();

  const choose = async () => addToSelection(await pickFilesSafely());

  const onSelect = async (device: NearbyDevice) => {
    let files = selection;
    if (files.length === 0) {
      files = await pickFilesSafely();
      if (files.length === 0) return;
    }
    if (await send(device, files)) clearSelection();
  };

  const header = (
    <View style={styles.header}>
      <View style={styles.brand}>
        <Logo />
        <Text
          variant="headline"
          style={styles.brandText}
          accessibilityRole="header"
        >
          CrossDrop
        </Text>
      </View>
      <RoundButton
        icon="settings"
        label="Settings"
        onPress={() => navigate('settings')}
      />
    </View>
  );

  const footer =
    selection.length === 0 ? (
      <View style={styles.footerGroup}>
        <Button title="Choose files" icon="plus" large onPress={choose} />
        <Text variant="footnote" tone="secondary" center>
          or share from any app
        </Text>
      </View>
    ) : (
      <View style={styles.footerGroup}>
        <Tray
          files={selection}
          onAdd={choose}
          onClear={clearSelection}
          onRemove={removeFromSelection}
        />
        <Text variant="footnote" tone="secondary" center>
          Tap a device to send
        </Text>
      </View>
    );

  return (
    <NearbyView
      snapshot={snapshot}
      files={selection}
      header={header}
      readyTitle={
        selection.length > 0
          ? `Send ${pluralFiles(selection.length)}`
          : 'Ready to send'
      }
      onSelect={onSelect}
      busy={busy}
      actionHint={device =>
        selection.length > 0
          ? `Sends ${pluralFiles(selection.length)} to ${device.name}`
          : `Choose files to send to ${device.name}`
      }
      footer={footer}
      bottomSpace={TAB_BAR_SPACE}
    />
  );
}

export { Tray };

const styles = StyleSheet.create({
  flex: { flex: 1 },
  content: { flexGrow: 1, gap: spacing.md },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  brand: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  brandText: { fontSize: 18, fontFamily: 'Poppins-Bold', letterSpacing: -0.3 },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'center',
    gap: 10,
    maxWidth: '100%',
    minHeight: 40,
    paddingLeft: 16,
    paddingRight: 6,
    paddingVertical: 6,
    borderRadius: 999,
    overflow: 'hidden',
  },
  pillText: { flexShrink: 1, color: '#2B3D33' },
  switch: {
    width: 40,
    height: 24,
    borderRadius: 12,
    padding: 2,
    justifyContent: 'center',
  },
  knob: {
    width: 20,
    height: 20,
    borderRadius: 10,
    backgroundColor: '#FFFFFF',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(0,0,0,0.12)',
  },
  titles: { gap: spacing.xs, paddingHorizontal: spacing.xxs },
  footer: { gap: spacing.sm },
  footerGroup: { gap: 10 },
  tips: {
    borderRadius: 22,
    overflow: 'hidden',
    paddingHorizontal: spacing.md,
    paddingVertical: 6,
  },
  tip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingVertical: 10,
  },
  tipNumber: {
    width: 26,
    height: 26,
    borderRadius: 13,
    backgroundColor: '#0F1D16',
    alignItems: 'center',
    justifyContent: 'center',
  },
  hairline: { height: 1 },
  tray: {
    borderRadius: 22,
    overflow: 'hidden',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  trayHead: { flexDirection: 'row', alignItems: 'center', gap: spacing.xxs },
});
