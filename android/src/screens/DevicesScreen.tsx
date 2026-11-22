import React, { useState } from 'react';
import { ActivityIndicator, Alert, StyleSheet, View } from 'react-native';
import { Badge } from '../components/Badge';
import { Button } from '../components/Button';
import { EmptyState } from '../components/EmptyState';
import { GlassCard } from '../components/GlassCard';
import { IconBubble } from '../components/IconBubble';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { Toggle } from '../components/Toggle';
import { RoomBanner } from '../components/RoomBanner';
import {
  joinWithCode,
  RoomSheet,
  scanAndJoin,
  StartRoomSheet,
} from '../components/RoomSheets';
import { errorCode, isRoomCode, pairError, platformLabel } from '../copy';
import {
  formatClock,
  formatDate,
  groupFingerprint,
  relativeTime,
} from '../format';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import type { Snapshot, TrustedDevice } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

function TrustedDeviceCard({
  device,
  now,
}: {
  device: TrustedDevice;
  now: number;
}) {
  const forget = () =>
    Alert.alert(
      `Forget ${device.name}?`,
      'It will need to confirm a new pairing code before it can send to or receive from this phone again.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Forget',
          style: 'destructive',
          onPress: () => CrossDrop.forgetDevice(device.deviceId),
        },
      ],
    );
  const lastUsed = device.lastUsedAt
    ? `Last used ${relativeTime(device.lastUsedAt, now).toLowerCase()}`
    : 'Not used yet';
  // Met in a Drip Room: trusted only until the room ends, never auto-accepted.
  const temporary = device.expiresAt !== null;

  return (
    <GlassCard style={styles.card}>
      <View style={styles.header}>
        <IconBubble
          name={device.platform === 'macos' ? 'laptop' : 'phone'}
          size={48}
        />
        <View style={styles.flex}>
          <Text variant="headline">{device.name}</Text>
          {temporary ? (
            <Badge
              label={`From a Drip Room · until ${formatClock(
                device.expiresAt!,
              )}`}
              tone="accent"
              icon="clock"
            />
          ) : null}
          <Text variant="footnote" tone="secondary">
            {platformLabel(device.platform)} · {temporary ? 'Joined' : 'Paired'}{' '}
            {formatDate(device.pairedAt)} · {lastUsed}
          </Text>
        </View>
      </View>
      <View
        style={styles.fingerprint}
        accessible
        accessibilityLabel={`Security fingerprint ${device.fingerprint
          .split('')
          .join(' ')}`}
      >
        <Text variant="caption" tone="tertiary">
          FINGERPRINT
        </Text>
        <Text variant="footnote" tone="secondary" mono selectable>
          {groupFingerprint(device.fingerprint)}
        </Text>
      </View>
      {temporary ? (
        <Text variant="footnote" tone="secondary" style={styles.tempNote}>
          Trusted only for the room. You confirm each transfer, and it’s
          forgotten when the room ends.
        </Text>
      ) : (
        <View style={styles.switchRow}>
          <View style={styles.flex}>
            <Text variant="callout">Accept files automatically</Text>
            <Text variant="footnote" tone="secondary">
              Files from {device.name} are saved without asking. You still get a
              notification.
            </Text>
          </View>
          <Toggle
            value={device.autoAccept}
            onValueChange={v => CrossDrop.setAutoAccept(device.deviceId, v)}
            accessibilityLabel={`Accept files automatically from ${device.name}`}
          />
        </View>
      )}
      <View style={styles.actions}>
        <Button
          title="Forget device"
          kind="destructive"
          compact
          icon="trash"
          onPress={forget}
          accessibilityLabel={`Forget ${device.name}`}
        />
      </View>
    </GlassCard>
  );
}

/** Pair by scanning the QR code a Mac shows: no numbers to compare. */
function QrPairCard() {
  const t = useTheme();
  const [mine, setMine] = useState(true);
  const [busy, setBusy] = useState(false);
  const scan = async () => {
    const code = await CrossDrop.scanPairingCode().catch(() => '');
    if (!code) return;
    setBusy(true);
    if (isRoomCode(code)) {
      // A Drip Room code works here too.
      await joinWithCode(code, false);
      setBusy(false);
      return;
    }
    try {
      const name = await CrossDrop.pairWithCode(code, mine);
      CrossDrop.feedback('done');
      Alert.alert(
        `Paired with ${name}`,
        mine
          ? 'Files from it now arrive without asking.'
          : 'You can now send files to each other.',
      );
    } catch (e) {
      CrossDrop.feedback('error');
      Alert.alert('Couldn’t pair', pairError(errorCode(e)));
    } finally {
      setBusy(false);
    }
  };
  return (
    <GlassCard tint={t.accentSoft}>
      <View style={styles.header}>
        <IconBubble name="qr" size={48} />
        <View style={styles.flex}>
          <Text variant="headline">Pair with a QR code</Text>
          <Text variant="footnote" tone="secondary">
            On your Mac, choose Pair a phone in the CrossDrop menu, then scan.
            Works even where devices can’t find each other.
          </Text>
        </View>
      </View>
      <View style={styles.switchRow}>
        <View style={styles.flex}>
          <Text variant="callout">This is my device</Text>
          <Text variant="footnote" tone="secondary">
            Files from it arrive without asking.
          </Text>
        </View>
        <Toggle
          value={mine}
          onValueChange={setMine}
          accessibilityLabel="This is my device"
        />
      </View>
      <View style={styles.actions}>
        {busy ? (
          <View style={styles.busy} accessibilityLiveRegion="polite">
            <ActivityIndicator color={t.link} />
            <Text variant="callout" tone="secondary">
              Pairing…
            </Text>
          </View>
        ) : (
          <Button title="Scan pairing code" icon="qr" onPress={scan} />
        )}
      </View>
    </GlassCard>
  );
}

/** Drip Rooms: a short-lived group where everyone who scans one code can swap files. */
function RoomsCard({ snapshot }: { snapshot: Snapshot }) {
  const t = useTheme();
  const [sheet, setSheet] = useState<'start' | 'room' | null>(null);
  const [joining, setJoining] = useState(false);
  const room = snapshot.room;
  const join = async () => {
    setJoining(true);
    try {
      await scanAndJoin(false);
    } finally {
      setJoining(false);
    }
  };
  return (
    <>
      <SectionHeader title="Drip Rooms" />
      {room ? (
        <RoomBanner room={room} onPress={() => setSheet('room')} />
      ) : (
        <GlassCard>
          <View style={styles.header}>
            <IconBubble name="users" size={48} />
            <View style={styles.flex}>
              <Text variant="headline">Swap files with a group</Text>
              <Text variant="footnote" tone="secondary">
                Start a room and others scan its code: everyone in it can send
                to each other without comparing codes, until it ends.
              </Text>
            </View>
          </View>
          <View style={styles.roomActions}>
            <Button
              title="Start a room"
              icon="plus"
              compact
              onPress={() => setSheet('start')}
            />
            {joining ? (
              <View style={styles.busy} accessibilityLiveRegion="polite">
                <ActivityIndicator color={t.link} />
                <Text variant="callout" tone="secondary">
                  Joining…
                </Text>
              </View>
            ) : (
              <Button
                title="Join by scanning"
                icon="qr"
                kind="secondary"
                compact
                onPress={join}
              />
            )}
          </View>
        </GlassCard>
      )}
      {sheet === 'start' ? (
        <StartRoomSheet
          snapshot={snapshot}
          onStarted={() => setSheet('room')}
          onClose={() => setSheet(null)}
        />
      ) : null}
      {sheet === 'room' && room ? (
        <RoomSheet room={room} onClose={() => setSheet(null)} />
      ) : null}
    </>
  );
}

export function DevicesScreen() {
  const snapshot = useSnapshot();
  const t = useTheme();
  const now = useNow(60000);
  return (
    <Screen title="Devices" subtitle="Devices you have paired with">
      <GlassCard
        tint={t.accentSoft}
        accessibilityLabel={`This phone, ${
          snapshot.local.name
        }. Fingerprint ${snapshot.local.fingerprint.split('').join(' ')}`}
      >
        <View style={styles.header}>
          <IconBubble name="phone" size={48} />
          <View style={styles.flex}>
            <Text variant="headline">{snapshot.local.name}</Text>
            <Badge label="This phone" tone="accent" />
          </View>
        </View>
        <View style={styles.fingerprint}>
          <Text variant="caption" tone="tertiary">
            FINGERPRINT
          </Text>
          <Text variant="footnote" tone="secondary" mono selectable>
            {groupFingerprint(snapshot.local.fingerprint)}
          </Text>
        </View>
      </GlassCard>

      <QrPairCard />

      <RoomsCard snapshot={snapshot} />

      <SectionHeader title="Paired" />
      {snapshot.trusted.length === 0 ? (
        <GlassCard>
          <EmptyState
            icon="shieldCheck"
            pose="pairing"
            title="No paired devices"
            detail="The first time two devices exchange files, both show the same 6-digit code to confirm. Paired devices appear here."
          />
        </GlassCard>
      ) : (
        snapshot.trusted.map(d => (
          <TrustedDeviceCard key={d.deviceId} device={d} now={now} />
        ))
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, gap: 2 },
  card: { marginBottom: spacing.sm },
  header: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  fingerprint: {
    marginTop: spacing.md,
    padding: spacing.sm,
    borderRadius: 14,
    gap: 2,
    backgroundColor: 'rgba(240,248,242,0.92)',
    borderWidth: 1,
    borderColor: '#E1EEE5',
  },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  actions: { flexDirection: 'row', marginTop: spacing.md },
  roomActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    marginTop: spacing.md,
  },
  tempNote: { marginTop: spacing.md },
  busy: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: 48,
  },
});
