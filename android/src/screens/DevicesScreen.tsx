import React from 'react';
import { Alert, StyleSheet, Switch, View } from 'react-native';
import { Badge } from '../components/Badge';
import { Button } from '../components/Button';
import { EmptyState } from '../components/EmptyState';
import { GlassCard } from '../components/GlassCard';
import { IconBubble } from '../components/IconBubble';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { platformLabel } from '../copy';
import { formatDate, groupFingerprint, relativeTime } from '../format';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import type { TrustedDevice } from '../native/types';
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
  const t = useTheme();
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

  return (
    <GlassCard style={styles.card}>
      <View style={styles.header}>
        <IconBubble
          name={device.platform === 'macos' ? 'laptop' : 'phone'}
          size={48}
        />
        <View style={styles.flex}>
          <Text variant="headline">{device.name}</Text>
          <Text variant="footnote" tone="secondary">
            {platformLabel(device.platform)} · Paired{' '}
            {formatDate(device.pairedAt)} · {lastUsed}
          </Text>
        </View>
      </View>
      <View
        style={[styles.fingerprint, { backgroundColor: t.track }]}
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
      <View style={styles.switchRow}>
        <View style={styles.flex}>
          <Text variant="callout">Accept files automatically</Text>
          <Text variant="footnote" tone="secondary">
            Files from {device.name} are saved without asking. You still get a
            notification.
          </Text>
        </View>
        <Switch
          value={device.autoAccept}
          onValueChange={v => CrossDrop.setAutoAccept(device.deviceId, v)}
          accessibilityLabel={`Accept files automatically from ${device.name}`}
          trackColor={{ false: t.track, true: t.accent }}
          thumbColor="#FFFFFF"
        />
      </View>
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
        <View style={[styles.fingerprint, { backgroundColor: t.track }]}>
          <Text variant="caption" tone="tertiary">
            FINGERPRINT
          </Text>
          <Text variant="footnote" tone="secondary" mono selectable>
            {groupFingerprint(snapshot.local.fingerprint)}
          </Text>
        </View>
      </GlassCard>

      <SectionHeader title="Paired" />
      {snapshot.trusted.length === 0 ? (
        <GlassCard>
          <EmptyState
            icon="shieldCheck"
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
    borderRadius: 12,
    gap: 2,
  },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  actions: { flexDirection: 'row', marginTop: spacing.md },
});
