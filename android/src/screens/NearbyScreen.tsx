import React, { useEffect, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Button } from '../components/Button';
import { RoundButton } from '../components/Chips';
import { ClipPill } from '../components/ClipPill';
import { DeviceRow } from '../components/DeviceRow';
import { DripStage } from '../components/DripStage';
import { FileRow } from '../components/FileRow';
import { Frost } from '../components/Frost';
import { Icon } from '../components/Icon';
import { Logo } from '../components/Logo';
import { ReceiveModeSheet } from '../components/ReceiveModeSheet';
import { RoomBanner } from '../components/RoomBanner';
import { RoomSheet } from '../components/RoomSheets';
import { TAB_BAR_SPACE } from '../components/Screen';
import { Sheet } from '../components/Sheet';
import { Text } from '../components/Text';
import { Toggle } from '../components/Toggle';
import { friendlyError } from '../copy';
import { formatBytes, formatClock, pluralFiles, sumSizes } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type {
  NearbyDevice,
  SharedFile,
  SharedText,
  Snapshot,
} from '../native/types';
import { useNavigation } from '../navigation/NavigationContext';
import { useCrossDrop, useSnapshot } from '../state/CrossDropProvider';
import { useReceivingToggle } from '../state/useReceiving';
import { useSendFlow } from '../state/useSendFlow';
import { pickFilesSafely } from '../state/useSendFiles';
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
  const [open, setOpen] = useState(false);
  const { receiving } = snapshot;
  const label =
    receiving.mode === 'everyone'
      ? receiving.autoOffAt !== null
        ? `Everyone · until ${formatClock(receiving.autoOffAt)}`
        : 'Receiving from everyone'
      : receiving.mode === 'mine'
      ? 'My devices · always ready'
      : 'Receiving off';
  return (
    <>
      <Pressable
        onPress={() => setOpen(true)}
        accessibilityRole="button"
        accessibilityLabel={`Receiving: ${label}`}
        accessibilityHint="Choose who can send to this phone"
        style={styles.pill}
      >
        <Frost radius={999} />
        <Text variant="subhead" style={styles.pillText} numberOfLines={1}>
          {label}
        </Text>
        <MiniSwitch on={receiving.enabled} />
      </Pressable>
      {open ? (
        <ReceiveModeSheet snapshot={snapshot} onClose={() => setOpen(false)} />
      ) : null}
    </>
  );
}

/** True for a moment after a new device appears, so Drip can wave hello. */
function useWave(newestDeviceAt: number): boolean {
  const [waving, setWaving] = useState(false);
  useEffect(() => {
    if (!newestDeviceAt || Date.now() - newestDeviceAt > 3000) return;
    setWaving(true);
    const timer = setTimeout(() => setWaving(false), 1400);
    return () => clearTimeout(timer);
  }, [newestDeviceAt]);
  return waving;
}

/** A link or text waiting to be sent (share sheet or clipboard). */
export function TextTray({
  text,
  onClear,
}: {
  text: SharedText;
  onClear?: () => void;
}) {
  const t = useTheme();
  return (
    <View style={styles.tray}>
      <Frost radius={22} />
      <View style={styles.trayHead}>
        <Icon
          name={text.kind === 'link' ? 'link' : 'clipboard'}
          size={18}
          color={t.link}
        />
        <Text variant="headline" style={styles.flex} numberOfLines={1}>
          {text.kind === 'link' ? 'Link' : 'Text'}
        </Text>
        {onClear ? (
          <Button
            title="Clear"
            kind="plain"
            compact
            onPress={onClear}
            accessibilityLabel={`Clear ${text.kind}`}
          />
        ) : null}
      </View>
      <Text
        variant="callout"
        tone="secondary"
        numberOfLines={text.kind === 'link' ? 2 : 4}
      >
        {text.preview}
      </Text>
      <Text variant="footnote" tone="tertiary">
        {text.kind === 'link'
          ? 'Opens on a Mac; a phone shows it to open.'
          : 'Lands on the other device’s clipboard. Not saved as a file.'}
      </Text>
    </View>
  );
}

/** Pick several devices, then send to all of them at once. */
function MultiSendSheet({
  devices,
  onSend,
  onClose,
}: {
  devices: NearbyDevice[];
  onSend: (devices: NearbyDevice[]) => void;
  onClose: () => void;
}) {
  const t = useTheme();
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const toggle = (id: string) =>
    setPicked(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const chosen = devices.filter(d => picked.has(d.deviceId));
  return (
    <Sheet
      visible
      onRequestClose={onClose}
      accessibilityLabel="Send to several devices"
    >
      <Text variant="title" accessibilityRole="header">
        Send to several
      </Text>
      <Text variant="callout" tone="secondary">
        Each device gets its own copy, verified separately.
      </Text>
      <View style={styles.multiList}>
        {devices.map(d => {
          const on = picked.has(d.deviceId);
          return (
            <Pressable
              key={d.deviceId}
              onPress={() => toggle(d.deviceId)}
              accessibilityRole="checkbox"
              accessibilityState={{ checked: on }}
              accessibilityLabel={d.name}
              style={[
                styles.multiRow,
                { backgroundColor: on ? 'rgba(20,154,91,0.10)' : t.inset },
              ]}
            >
              <Icon
                name={d.platform === 'macos' ? 'laptop' : 'phone'}
                size={22}
                color={t.textPrimary}
              />
              <Text variant="headline" style={styles.flex} numberOfLines={1}>
                {d.name}
              </Text>
              <View
                style={[
                  styles.check,
                  on
                    ? { backgroundColor: green, borderColor: green }
                    : { borderColor: t.textTertiary },
                ]}
              >
                {on ? <Icon name="check" size={16} color="#FFFFFF" /> : null}
              </View>
            </Pressable>
          );
        })}
      </View>
      <Button
        title={
          chosen.length > 1
            ? `Send to ${chosen.length} devices`
            : chosen.length === 1
            ? `Send to ${chosen[0].name}`
            : 'Choose devices'
        }
        icon="send"
        large
        disabled={chosen.length === 0}
        onPress={() => onSend(chosen)}
      />
    </Sheet>
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

/** The "Auto-delete after 24 h" sending option (asks the receiver to delete, §9.8). */
function AutoDeleteRow({
  value,
  onChange,
}: {
  value: boolean;
  onChange: (on: boolean) => void;
}) {
  const t = useTheme();
  return (
    <View style={styles.autoDelete}>
      <View
        style={[
          styles.hairline,
          styles.autoLine,
          { backgroundColor: t.hairline },
        ]}
      />
      <View style={styles.autoRow}>
        <Icon name="clock" size={18} color={value ? green : t.textTertiary} />
        <View style={styles.flex}>
          <Text variant="subhead">Auto-delete after 24 h</Text>
          <Text variant="footnote" tone="secondary">
            CrossDrop on the other device deletes them a day after they arrive.
            Copies made before then aren’t affected.
          </Text>
        </View>
        <Toggle
          value={value}
          onValueChange={onChange}
          accessibilityLabel="Auto-delete after 24 hours"
          accessibilityHint="Asks the receiving device to delete these files a day after they arrive"
        />
      </View>
    </View>
  );
}

function Tray({
  files,
  onAdd,
  onClear,
  onRemove,
  autoDelete,
  onAutoDelete,
}: {
  files: SharedFile[];
  onAdd?: () => void;
  onClear?: () => void;
  onRemove?: (uri: string) => void;
  /** Shows the auto-delete option when set. */
  autoDelete?: boolean;
  onAutoDelete?: (on: boolean) => void;
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
      {autoDelete !== undefined && onAutoDelete ? (
        <AutoDeleteRow value={autoDelete} onChange={onAutoDelete} />
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
  /** Send to several devices at once (offered when two or more are around). */
  onSelectMany?: (devices: NearbyDevice[]) => void;
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
  onSelectMany,
  busy,
  actionHint,
  footer,
  bottomSpace,
}: NearbyViewProps) {
  const insets = useSafeAreaInsets();
  const toggleReceiving = useReceivingToggle(snapshot);
  const [showAll, setShowAll] = useState(false);
  const [showMulti, setShowMulti] = useState(false);
  const [showRoom, setShowRoom] = useState(false);
  const waving = useWave(snapshot.newestDeviceAt);
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
      if (onSelectMany && count > 1) {
        action = (
          <View style={styles.footerGroup}>
            {footer}
            <Button
              title="Send to several"
              icon="layers"
              kind="plain"
              compact
              onPress={() => setShowMulti(true)}
            />
          </View>
        );
      }
      stage = (
        <DripStage
          pose="nearby"
          motion={waving ? 'wave' : 'bob'}
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
        'Receiving is off, so nearby Macs can’t see this phone. Macs that are receiving still show up here.';
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
        {snapshot.room ? (
          <RoomBanner room={snapshot.room} onPress={() => setShowRoom(true)} />
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
      {showRoom && snapshot.room ? (
        <RoomSheet room={snapshot.room} onClose={() => setShowRoom(false)} />
      ) : null}
      {showMulti && onSelectMany ? (
        <MultiSendSheet
          devices={snapshot.nearby}
          onClose={() => setShowMulti(false)}
          onSend={devices => {
            setShowMulti(false);
            onSelectMany(devices);
          }}
        />
      ) : null}
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
  const insets = useSafeAreaInsets();
  const { navigate } = useNavigation();
  const {
    selection,
    addToSelection,
    removeFromSelection,
    clearSelection,
    autoDelete,
    setAutoDelete,
  } = useCrossDrop();
  const flow = useSendFlow({
    resolveFiles: async () =>
      selection.length > 0 ? selection : pickFilesSafely(),
    count: selection.length,
    text: null,
    onDone: clearSelection,
  });
  const busy = flow.busy;

  const choose = async () => addToSelection(await pickFilesSafely());
  const chooseFolder = async () => {
    try {
      const files = await CrossDrop.pickFolder();
      if (files.length > 0) addToSelection(files);
    } catch (e) {
      Alert.alert(
        'Couldn’t open folders',
        e instanceof Error ? e.message : 'Try again.',
      );
    }
  };
  const pasteClipboard = async () => {
    // The share screen takes over once the clipboard text is offered.
    if (!(await CrossDrop.takeClipboard().catch(() => false))) {
      Alert.alert(
        'Nothing to send',
        'Copy a link or some text first, then tap Clipboard again.',
      );
    }
  };

  const onSelect = flow.select;
  const onSelectMany = flow.selectMany;
  const clip =
    snapshot.clip && snapshot.clip.expiresAt > Date.now()
      ? snapshot.clip
      : null;

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
        <View style={styles.extraRow}>
          <Button
            title="Folder"
            icon="folder"
            kind="secondary"
            compact
            onPress={chooseFolder}
            accessibilityLabel="Choose a folder to send"
          />
          <Button
            title="Clipboard"
            icon="clipboard"
            kind="secondary"
            compact
            onPress={pasteClipboard}
            accessibilityLabel="Send what's on the clipboard"
          />
        </View>
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
          autoDelete={autoDelete}
          onAutoDelete={setAutoDelete}
        />
        <Text variant="footnote" tone="secondary" center>
          Tap a device to send
        </Text>
      </View>
    );

  return (
    <View style={styles.flex}>
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
        onSelectMany={onSelectMany}
        busy={busy}
        actionHint={device =>
          selection.length > 0
            ? `Sends ${pluralFiles(selection.length)} to ${device.name}`
            : `Choose files to send to ${device.name}`
        }
        footer={footer}
        bottomSpace={TAB_BAR_SPACE}
      />
      {clip ? (
        <View
          pointerEvents="box-none"
          style={[
            styles.clip,
            {
              top: insets.top + spacing.xs,
              left: insets.left + spacing.md,
              right: insets.right + spacing.md,
            },
          ]}
        >
          <ClipPill key={clip.transferId} clip={clip} />
        </View>
      ) : null}
      {flow.element}
    </View>
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
  extraRow: { flexDirection: 'row', justifyContent: 'center', gap: spacing.sm },
  multiList: { gap: spacing.xs, marginVertical: spacing.sm },
  multiRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    borderRadius: 18,
    paddingHorizontal: spacing.md,
    minHeight: 56,
  },
  check: {
    width: 26,
    height: 26,
    borderRadius: 13,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
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
  autoDelete: { marginTop: spacing.xs },
  autoLine: { marginBottom: spacing.xxs },
  autoRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  clip: { position: 'absolute', zIndex: 10 },
});
