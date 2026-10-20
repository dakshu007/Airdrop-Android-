import React from 'react';
import { StyleSheet, View } from 'react-native';
import { friendlyError } from '../copy';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice, Snapshot } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import { Button } from './Button';
import { DeviceCard } from './DeviceCard';
import { GlassCard } from './GlassCard';
import { Icon, IconName } from './Icon';
import { Notice } from './Notice';
import { Radar } from './Radar';
import { Text } from './Text';

interface Props {
  snapshot: Snapshot;
  onSelect: (device: NearbyDevice) => void;
  actionHint: (device: NearbyDevice) => string;
  busy?: boolean;
}

const TIPS: { icon: IconName; text: string }[] = [
  {
    icon: 'laptop',
    text: 'Open CrossDrop on your Mac and switch on Receiving.',
  },
  { icon: 'wifi', text: 'Keep both devices on the same Wi-Fi network.' },
  {
    icon: 'shield',
    text: 'Guest networks and some office or hotel Wi-Fi stop devices from seeing each other (client isolation).',
  },
];

/** Discovery status, radar and nearby devices — shared by the Nearby screen and the share flow. */
export function NearbyDeviceList({
  snapshot,
  onSelect,
  actionHint,
  busy,
}: Props) {
  const t = useTheme();
  const { discovery, network, nearby } = snapshot;

  if (!network.localNetwork) {
    const e = friendlyError('no_network');
    return (
      <Notice
        tone="warning"
        icon="wifiOff"
        title={e.title}
        detail="CrossDrop sends files over your local Wi-Fi. Connect this phone to the same network as your Mac."
      />
    );
  }

  if (discovery.error) {
    const e = friendlyError(discovery.error);
    return (
      <Notice
        tone="danger"
        title={e.title}
        detail={e.detail}
        action={
          <Button
            title="Try again"
            kind="secondary"
            compact
            icon="refresh"
            onPress={() => {
              CrossDrop.stopDiscovery();
              CrossDrop.startDiscovery();
            }}
          />
        }
      />
    );
  }

  return (
    <View>
      <View style={styles.radar}>
        <Radar scanning={discovery.active} />
        <Text
          variant="footnote"
          tone="secondary"
          center
          accessibilityLiveRegion="polite"
        >
          {discovery.active
            ? nearby.length === 0
              ? 'Looking for nearby devices…'
              : `${nearby.length} nearby ${
                  nearby.length === 1 ? 'device' : 'devices'
                }`
            : 'Paused'}
        </Text>
      </View>
      {nearby.map(device => (
        <DeviceCard
          key={device.deviceId}
          device={device}
          onPress={() => onSelect(device)}
          actionHint={actionHint(device)}
          disabled={busy}
        />
      ))}
      {nearby.length === 0 ? (
        <GlassCard>
          <Text variant="headline" style={styles.tipsTitle}>
            No devices yet
          </Text>
          {TIPS.map(tip => (
            <View key={tip.text} style={styles.tip}>
              <Icon name={tip.icon} size={20} color={t.textSecondary} />
              <Text variant="callout" tone="secondary" style={styles.tipText}>
                {tip.text}
              </Text>
            </View>
          ))}
        </GlassCard>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  radar: { alignItems: 'center', gap: spacing.xs, marginBottom: spacing.lg },
  tipsTitle: { marginBottom: spacing.xs },
  tip: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-start',
    paddingVertical: spacing.xs,
  },
  tipText: { flex: 1 },
});
