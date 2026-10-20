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
import { useReceivingToggle } from '../state/useReceiving';
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
  const toggleReceiving = useReceivingToggle(snapshot);
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
          icon="download"
          title="Receiving"
          detail="Turns off after 10 minutes to save battery"
          trailing={
            <Toggle
              value={snapshot.receiving.enabled}
              onValueChange={toggleReceiving}
              accessibilityLabel="Receiving"
              accessibilityHint="Lets nearby devices send to this phone"
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
          title="Quick Settings tile"
          detail="Switch Receiving from Quick Settings. Add the tile from the Quick Settings edit panel — Android asks you to add it yourself."
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
          detail="A light tap for codes and finished transfers"
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
