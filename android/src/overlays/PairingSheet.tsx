import React from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { IconBubble } from '../components/IconBubble';
import { Specular } from '../components/Specular';
import { Text } from '../components/Text';
import { platformLabel } from '../copy';
import { countdown, formatPairingCode, spokenPairingCode } from '../format';
import type { PairingPrompt } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';

interface Props {
  prompt: PairingPrompt;
  now: number;
  responded: boolean;
  onRespond: (accept: boolean) => void;
}

export function PairingSheetContent({
  prompt,
  now,
  responded,
  onRespond,
}: Props) {
  const t = useTheme();
  const peerKind = platformLabel(prompt.peerPlatform);
  const waiting = prompt.waitingForPeer || responded;
  const intro =
    prompt.role === 'receiver'
      ? `${prompt.peerName} wants to send you files. Pair once so these devices recognise each other next time.`
      : `This is the first time you’re sending to ${prompt.peerName}. Pair once so these devices recognise each other.`;

  return (
    <>
      <View style={styles.header}>
        <IconBubble name="shieldCheck" size={56} />
        <Text variant="title" center accessibilityRole="header">
          Pair with {prompt.peerName}?
        </Text>
        <Text variant="callout" tone="secondary" center>
          {intro}
        </Text>
      </View>

      <View
        style={[
          styles.codeBox,
          { backgroundColor: t.accentSoft, borderColor: t.glassBorder },
        ]}
        accessible
        accessibilityLabel={`Pairing code ${spokenPairingCode(prompt.code)}`}
      >
        <Specular color={t.specular} />
        <Text variant="code" center tone="primary" style={styles.code}>
          {formatPairingCode(prompt.code)}
        </Text>
      </View>

      <Text variant="callout" center>
        Check that the same code is shown on {prompt.peerName} ({peerKind}).
        Only confirm if they match.
      </Text>

      {waiting ? (
        <View style={styles.waiting} accessibilityLiveRegion="polite">
          <ActivityIndicator color={t.textSecondary} />
          <Text variant="callout" tone="secondary">
            Waiting for {prompt.peerName} to confirm…
          </Text>
        </View>
      ) : (
        <Button
          title="Codes match"
          icon="check"
          onPress={() => onRespond(true)}
        />
      )}
      <Button
        title={waiting ? 'Cancel pairing' : 'Codes don’t match'}
        kind="secondary"
        onPress={() => onRespond(false)}
      />
      <Text
        variant="footnote"
        tone="tertiary"
        center
        accessibilityLiveRegion="none"
      >
        Expires in {countdown(prompt.expiresAt - now)}
      </Text>
    </>
  );
}

const styles = StyleSheet.create({
  header: { alignItems: 'center', gap: spacing.xs },
  codeBox: {
    borderRadius: radii.md,
    borderWidth: 1,
    paddingVertical: spacing.lg,
    paddingHorizontal: spacing.md,
    overflow: 'hidden',
  },
  code: { fontVariant: ['tabular-nums'] },
  waiting: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    minHeight: 48,
  },
});
