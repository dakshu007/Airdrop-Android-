import React from 'react';
import { StyleSheet, View } from 'react-native';
import { friendlyError } from '../copy';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice, Snapshot } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Button } from './Button';
import { DeviceRow } from './DeviceRow';
import { GlassCard } from './GlassCard';
import { Icon, IconName } from './Icon';
import { Notice } from './Notice';
import { Radar } from './Radar';
import { SectionHeader } from './SectionHeader';
import { Text } from './Text';

interface Props {
  snapshot: Snapshot;
  onSelect: (device: NearbyDevice) => void;
  actionHint: (device: NearbyDevice) => string;
  busy?: boolean;
  /** Rendered at the bottom of the radar card (send actions or the shared files). */
  heroFooter?: React.ReactNode;
}

const TIPS: { icon: IconName; text: string }[] = [
  { icon: 'laptop', text: 'Open CrossDrop on your Mac and switch on Receiving.' },
  { icon: 'wifi', text: 'Keep both devices on the same Wi-Fi network.' },
  {
    icon: 'shield',
    text: 'Guest networks and some office or hotel Wi-Fi stop devices from seeing each other.',
  },
];

/**
 * The radar card plus the list of nearby devices. Shared by the Nearby screen
 * and the share-sheet flow.
 */
export function NearbyDeviceList({ snapshot, onSelect, actionHint, busy, heroFooter }: Props) {
  const t = useTheme();
  const { discovery, network, nearby } = snapshot;

  let problem: React.ReactNode = null;
  if (!network.localNetwork) {
    const e = friendlyError('no_network');
    problem = (
      <Notice
        tone="warning"
        icon="wifiOff"
        title={e.title}
        detail="CrossDrop sends files over your local Wi-Fi. Connect this phone to the same network as your Mac."
      />
    );
  } else if (discovery.error) {
    const e = friendlyError(discovery.error);
    problem = (
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

  const scanning = discovery.active && !problem;
  const status = problem
    ? 'Discovery paused'
    : !discovery.active
    ? 'Paused'
    : nearby.length === 0
    ? 'Looking for nearby devices…'
    : `${nearby.length} ${nearby.length === 1 ? 'device' : 'devices'} nearby · tap one to send`;

  return (
    <View>
      {problem ? <View style={styles.problem}>{problem}</View> : null}
      <GlassCard radius={radii.lg} padding={spacing.md}>
        <Radar scanning={scanning} devices={problem ? [] : nearby} onSelect={onSelect} />
        <Text variant="footnote" tone="secondary" center accessibilityLiveRegion="polite" style={styles.status}>
          {status}
        </Text>
        {heroFooter ? <View style={styles.footer}>{heroFooter}</View> : null}
      </GlassCard>

      {problem ? null : (
        <>
          <SectionHeader title="Nearby" />
          {nearby.length > 0 ? (
            <GlassCard radius={radii.lg} padding={6}>
              {nearby.map((device, i) => (
                <View key={device.deviceId}>
                  {i > 0 ? <View style={styles.divider} /> : null}
                  <DeviceRow
                    device={device}
                    onPress={() => onSelect(device)}
                    actionHint={actionHint(device)}
                    disabled={busy}
                  />
                </View>
              ))}
            </GlassCard>
          ) : (
            <GlassCard radius={radii.lg}>
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
          )}
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  problem: { marginBottom: spacing.md },
  status: { marginTop: spacing.xs },
  footer: { marginTop: spacing.md },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: 'rgba(255,255,255,0.22)',
    marginHorizontal: spacing.sm,
  },
  tipsTitle: { marginBottom: spacing.xs },
  tip: { flexDirection: 'row', gap: spacing.sm, alignItems: 'flex-start', paddingVertical: spacing.xs },
  tipText: { flex: 1 },
});
