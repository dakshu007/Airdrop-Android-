import React, { useEffect, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { Button } from '../components/Button';
import { GlassCard } from '../components/GlassCard';
import { Icon, IconName } from '../components/Icon';
import { IconBubble } from '../components/IconBubble';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { Toggle } from '../components/Toggle';
import * as CrossDrop from '../native/crossdrop';
import type { NotificationPermission } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useReceiveMode } from '../state/useReceiving';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, radii, spacing, typography } from '../theme/tokens';

export const APP_VERSION = '0.1.0';
const MAX_NAME = 64;

function Row({
  icon,
  title,
  detail,
  trailing,
  children,
}: {
  icon?: IconName;
  title: string;
  detail?: string;
  trailing?: React.ReactNode;
  children?: React.ReactNode;
}) {
  return (
    <View style={styles.row}>
      {icon ? <IconBubble name={icon} size={36} /> : null}
      <View style={styles.flex}>
        <Text variant="callout" style={styles.rowTitle}>
          {title}
        </Text>
        {detail ? (
          <Text variant="footnote" tone="secondary">
            {detail}
          </Text>
        ) : null}
        {children}
      </View>
      {trailing}
    </View>
  );
}

function Divider() {
  const t = useTheme();
  return <View style={[styles.divider, { backgroundColor: t.hairline }]} />;
}

const NOTIFICATION_TEXT: Record<NotificationPermission, string> = {
  granted: 'On. File names are hidden on the lock screen.',
  notRequired: 'On. File names are hidden on the lock screen.',
  undetermined: 'Used to show receiving status and incoming files.',
  denied:
    'Off. You won’t be told about incoming files while CrossDrop is in the background.',
};

export function SettingsScreen() {
  const snapshot = useSnapshot();
  const t = useTheme();
  const setMode = useReceiveMode(snapshot);
  const [name, setName] = useState(snapshot.local.name);
  const [focused, setFocused] = useState(false);

  useEffect(() => {
    if (!focused) {
      setName(snapshot.local.name);
    }
  }, [snapshot.local.name, focused]);

  const trimmed = name.trim();
  const nameChanged = trimmed.length > 0 && trimmed !== snapshot.local.name;
  const saveName = () => {
    if (nameChanged) {
      CrossDrop.setDeviceName(trimmed.slice(0, MAX_NAME));
    } else {
      setName(snapshot.local.name);
    }
  };

  const permission = snapshot.notificationPermission;
  const { prefs } = snapshot;

  return (
    <Screen title="Settings">
      <GlassCard>
        <Text variant="subhead" tone="secondary" nativeID="deviceNameLabel">
          Name nearby devices see
        </Text>
        <TextInput
          value={name}
          onChangeText={setName}
          onFocus={() => setFocused(true)}
          onBlur={() => {
            setFocused(false);
            saveName();
          }}
          onSubmitEditing={saveName}
          maxLength={MAX_NAME}
          returnKeyType="done"
          autoCorrect={false}
          accessibilityLabel="Device name"
          accessibilityHint="Shown to nearby devices"
          aria-labelledby="deviceNameLabel"
          placeholder="Name shown to nearby devices"
          placeholderTextColor={t.textTertiary}
          style={[
            styles.input,
            typography.body,
            {
              color: t.textPrimary,
              borderColor: focused ? t.focus : '#D5E7DB',
            },
          ]}
        />
        <Text variant="footnote" tone="secondary">
          Use something you’ll recognise, without personal details.
        </Text>
      </GlassCard>

      <SectionHeader title="Receiving" />
      <GlassCard padding={spacing.sm}>
        <Row
          icon="heart"
          title="Always ready for my devices"
          detail="Devices you paired can send any time, even when CrossDrop is closed. Invisible to everyone else. Keeps a quiet notification while on."
          trailing={
            <Toggle
              value={snapshot.receiving.base === 'mine'}
              onValueChange={v => setMode(v ? 'mine' : 'off')}
              accessibilityLabel="Always ready for my devices"
            />
          }
        />
        <Divider />
        <Row
          icon="radar"
          title="Everyone nearby"
          detail="Anyone nearby can ask to send for the next 10 minutes. New devices confirm a code first."
          trailing={
            <Toggle
              value={snapshot.receiving.mode === 'everyone'}
              onValueChange={v =>
                setMode(v ? 'everyone' : snapshot.receiving.base)
              }
              accessibilityLabel="Receive from everyone nearby"
            />
          }
        />
        <Divider />
        <Row
          icon="folder"
          title="Saved to"
          detail={snapshot.destinationLabel}
          trailing={
            <Button
              title="Open"
              kind="plain"
              compact
              onPress={() => CrossDrop.openDownloads()}
            />
          }
        />
        <Divider />
        <Row
          icon="layers"
          title="Sort by type"
          detail={
            prefs.sortByType
              ? 'Smart arrival is on: photos, videos and music land in Pictures, Movies and Music › CrossDrop, so they show up in your gallery and music apps. Other files and whole folders stay in Download/CrossDrop.'
              : 'Smart arrival: put photos, videos and music in Pictures, Movies and Music › CrossDrop instead of Downloads. Other files and whole folders stay in Download/CrossDrop.'
          }
          trailing={
            <Toggle
              value={prefs.sortByType}
              onValueChange={v => CrossDrop.setPreference('sortByType', v)}
              accessibilityLabel="Sort by type"
              accessibilityHint="Saves photos, videos and music to their own folders"
            />
          }
        />
        <Divider />
        <Row
          icon="bell"
          title="Notifications"
          detail={NOTIFICATION_TEXT[permission]}
        >
          {permission === 'undetermined' ? (
            <View style={styles.inlineAction}>
              <Button
                title="Allow notifications"
                kind="secondary"
                compact
                onPress={() =>
                  CrossDrop.requestNotificationPermission().catch(
                    () => undefined,
                  )
                }
              />
            </View>
          ) : null}
          {permission === 'denied' ? (
            <View style={styles.inlineAction}>
              <Button
                title="Open app settings"
                kind="secondary"
                compact
                onPress={() => CrossDrop.openAppSettings()}
              />
            </View>
          ) : null}
        </Row>
        <Divider />
        <Row
          icon="tile"
          title="Quick Settings tiles"
          detail="“CrossDrop” switches Receiving; “Send clipboard” sends what you copied in two taps. Add them from the Quick Settings edit panel — Android asks you to add tiles yourself."
        />
        <Divider />
        <Row
          icon="image"
          title="Offer to send screenshots"
          detail={
            snapshot.prefs.screenshotOffer && !snapshot.screenshotPermission
              ? 'Needs photo access. Allow it in app settings.'
              : 'After a screenshot, a notification offers to send it to the device you used last. Works while CrossDrop is receiving.'
          }
          trailing={
            <Toggle
              value={snapshot.prefs.screenshotOffer}
              onValueChange={v =>
                CrossDrop.setScreenshotOffer(v).catch(() => false)
              }
              accessibilityLabel="Offer to send screenshots"
            />
          }
        />
      </GlassCard>

      <SectionHeader title="Experimental" />
      <GlassCard padding={spacing.sm}>
        <Row
          icon="wifi"
          title="No-router mode (phone hotspot)"
          detail={
            snapshot.hotspot.state === 'unsupported'
              ? 'Needs Android 13 or later.'
              : 'This phone opens its own Wi‑Fi for your Mac to join, for places without a shared network. Doesn’t share mobile data. Not yet tested on real devices.'
          }
          trailing={
            <Toggle
              value={
                snapshot.hotspot.state === 'on' ||
                snapshot.hotspot.state === 'starting'
              }
              disabled={snapshot.hotspot.state === 'unsupported'}
              onValueChange={v => CrossDrop.setHotspot(v).catch(() => false)}
              accessibilityLabel="No-router mode, phone hotspot"
            />
          }
        >
          {snapshot.hotspot.state === 'on' && snapshot.hotspot.ssid ? (
            <View style={styles.hotspot} accessible>
              <Text variant="footnote" tone="secondary">
                On the Mac, join this Wi‑Fi, then use CrossDrop as usual:
              </Text>
              <Text variant="callout" mono selectable>
                {snapshot.hotspot.ssid}
              </Text>
              {snapshot.hotspot.password ? (
                <Text variant="callout" mono selectable>
                  Password: {snapshot.hotspot.password}
                </Text>
              ) : null}
            </View>
          ) : null}
          {snapshot.hotspot.state === 'failed' ? (
            <Text variant="footnote" tone="danger">
              {snapshot.hotspot.error === 'tethering_disallowed'
                ? 'This phone or carrier doesn’t allow hotspots.'
                : snapshot.hotspot.error === 'incompatible_mode'
                ? 'Turn off the regular hotspot first.'
                : 'Couldn’t start the hotspot.'}
            </Text>
          ) : null}
        </Row>
        <Divider />
        <Row
          icon="bolt"
          title="Turbo"
          detail="When you send several files, asks for up to 4 parallel connections so they can move side by side. Only helps when the other device supports it too; with one file nothing changes. Speed gains haven’t been measured on real devices yet."
          trailing={
            <Toggle
              value={prefs.turbo}
              onValueChange={v => CrossDrop.setPreference('turbo', v)}
              accessibilityLabel="Turbo, experimental"
              accessibilityHint="Sends several files over parallel connections"
            />
          }
        />
      </GlassCard>

      <SectionHeader title="Feedback" />
      <GlassCard padding={spacing.sm}>
        <Row
          icon="sound"
          title="Sound when done"
          detail="A soft drop when files are verified. Silent when your phone is on silent or vibrate."
          trailing={
            <Toggle
              value={prefs.sound}
              onValueChange={v => CrossDrop.setPreference('sound', v)}
              accessibilityLabel="Sound when done"
            />
          }
        />
        <Divider />
        <Row
          icon="vibrate"
          title="Haptics"
          detail="A light tap for codes and finished transfers, and a soft heartbeat at every 10% while files move, so you can feel progress with the phone in your pocket. Follows Android’s touch-feedback setting."
          trailing={
            <Toggle
              value={prefs.haptics}
              onValueChange={v => CrossDrop.setPreference('haptics', v)}
              accessibilityLabel="Haptics"
            />
          }
        />
      </GlassCard>

      <SectionHeader title="Privacy" />
      <View style={styles.privacy} accessible>
        <Icon name="shieldCheck" size={22} color="#9BE6A6" />
        <View style={styles.flex}>
          <Text variant="headline" tone="onAccent">
            Stays on your Wi‑Fi
          </Text>
          <Text variant="footnote" style={styles.privacyText}>
            Files go straight between your devices, encrypted in transit. No
            account, no cloud, no tracking.
          </Text>
        </View>
      </View>
      <GlassCard padding={spacing.sm} style={styles.after}>
        <Row
          icon="lock"
          title="You approve new devices"
          detail="A device you haven’t paired with must match a 6-digit code on both screens, and you approve incoming files unless you turn on automatic acceptance for a paired device."
        />
        <Divider />
        <Row
          icon="info"
          title="What this doesn’t protect"
          detail="Other devices on the same Wi‑Fi can see this phone’s name while Receiving is on. Only accept files you expect."
        />
      </GlassCard>

      <SectionHeader title="About" />
      <GlassCard padding={spacing.sm}>
        <Row
          icon="drop"
          title={`CrossDrop ${snapshot.appVersion || APP_VERSION}`}
          detail="Protocol version 1 · Transfer history stays on this phone. Illustrations of Drip are original to CrossDrop."
        />
      </GlassCard>
    </Screen>
  );
}

const styles = StyleSheet.create({
  hotspot: { gap: 4, marginTop: spacing.xs },
  flex: { flex: 1, gap: 1 },
  row: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'center',
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.xxs,
    minHeight: minTouch + 8,
  },
  rowTitle: { fontFamily: 'Poppins-Medium', fontSize: 15 },
  inlineAction: { flexDirection: 'row', marginTop: spacing.xs },
  divider: { height: 1, marginVertical: 2, marginLeft: 48 + spacing.xxs },
  input: {
    minHeight: minTouch,
    borderWidth: 1.5,
    borderRadius: radii.sm,
    backgroundColor: '#FFFFFF',
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    marginTop: spacing.xs,
    marginBottom: spacing.xs,
  },
  privacy: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-start',
    borderRadius: radii.md,
    padding: spacing.md,
    backgroundColor: 'rgba(15,29,22,0.94)',
  },
  privacyText: { color: '#C9D8CF' },
  after: { marginTop: spacing.sm },
});
