import React, { useEffect, useState } from 'react';
import { StyleSheet, TextInput, View } from 'react-native';
import { Button } from '../components/Button';
import { GlassCard } from '../components/GlassCard';
import { Icon, IconName } from '../components/Icon';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { WallpaperPicker } from '../components/WallpaperPicker';
import * as CrossDrop from '../native/crossdrop';
import type { NotificationPermission } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, radii, spacing, typography } from '../theme/tokens';

export const APP_VERSION = '0.1.0';
const MAX_NAME = 64;

function Row({
  icon,
  title,
  detail,
  children,
}: {
  icon: IconName;
  title: string;
  detail?: string;
  children?: React.ReactNode;
}) {
  const t = useTheme();
  return (
    <View style={styles.row}>
      <Icon name={icon} size={22} color={t.textSecondary} />
      <View style={styles.flex}>
        <Text variant="callout">{title}</Text>
        {detail ? (
          <Text variant="footnote" tone="secondary">
            {detail}
          </Text>
        ) : null}
        {children}
      </View>
    </View>
  );
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

  return (
    <Screen title="Settings">
      <SectionHeader title="Wallpaper" />
      <GlassCard>
        <WallpaperPicker value={snapshot.wallpaper} />
      </GlassCard>

      <SectionHeader title="This phone" />
      <GlassCard>
        <Text variant="subhead" tone="secondary" nativeID="deviceNameLabel">
          Device name
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
              borderColor: focused ? t.focus : t.glassBorder,
              backgroundColor: 'rgba(6,8,20,0.22)',
            },
          ]}
        />
        <Text variant="footnote" tone="tertiary">
          Nearby devices see this name. Use something you’ll recognise, without
          personal details.
        </Text>
      </GlassCard>

      <SectionHeader title="Receiving" />
      <GlassCard>
        <Row icon="folder" title="Saved to" detail={snapshot.destinationLabel}>
          <View style={styles.inlineAction}>
            <Button
              title="Open Downloads"
              kind="secondary"
              compact
              onPress={() => CrossDrop.openDownloads()}
            />
          </View>
        </Row>
        <View style={styles.divider} />
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
        <View style={styles.divider} />
        <Row
          icon="tile"
          title="Quick Settings tile"
          detail="Switch Receiving on or off from Quick Settings. Add it from your Quick Settings edit panel — Android requires you to add it yourself."
        />
      </GlassCard>

      <SectionHeader title="Privacy" />
      <GlassCard>
        <Row
          icon="lock"
          title="Local network only"
          detail="Files go directly between your devices over your Wi-Fi, encrypted in transit. There are no accounts, no cloud storage and no analytics."
        />
        <View style={styles.divider} />
        <Row
          icon="shieldCheck"
          title="You approve new devices"
          detail="A device you haven’t paired with must match a 6-digit code on both screens, and you approve incoming files unless you turn on automatic acceptance for a paired device."
        />
        <View style={styles.divider} />
        <Row
          icon="info"
          title="What this doesn’t protect"
          detail="Other devices on the same Wi-Fi can see this phone’s name while Receiving is on. Only accept files you expect."
        />
      </GlassCard>

      <SectionHeader title="About" />
      <GlassCard>
        <Row
          icon="drop"
          title={`CrossDrop ${snapshot.appVersion || APP_VERSION}`}
          detail="Protocol version 1 · Transfer history stays on this phone."
        />
      </GlassCard>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, gap: 2 },
  row: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-start',
    paddingVertical: spacing.xs,
  },
  inlineAction: { flexDirection: 'row', marginTop: spacing.xs },
  divider: { height: StyleSheet.hairlineWidth, marginVertical: spacing.xs, backgroundColor: 'rgba(255,255,255,0.22)' },
  input: {
    minHeight: minTouch,
    borderWidth: 1.5,
    borderRadius: radii.sm,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    marginTop: spacing.xs,
    marginBottom: spacing.xs,
  },
});
