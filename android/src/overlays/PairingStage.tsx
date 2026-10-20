import React from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { RoundButton, StatusPill } from '../components/Chips';
import { CodeTiles } from '../components/CodeTiles';
import { Drip } from '../components/Drip';
import { Frost } from '../components/Frost';
import { Stage, useArtSize } from '../components/Stage';
import { Text } from '../components/Text';
import { countdown, spokenPairingCode } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { PairingPrompt } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

interface Props {
  prompt: PairingPrompt;
  now: number;
  responded: boolean;
  onRespond: (accept: boolean) => void;
}

/** First contact with a device: both screens show the same six digits. */
export function PairingStage({ prompt, now, responded, onRespond }: Props) {
  const t = useTheme();
  const art = useArtSize(0.24, 210, 130);
  const waiting = prompt.waitingForPeer || responded;
  const intro =
    prompt.role === 'receiver'
      ? `${prompt.peerName} wants to send you files and is showing a code too. Pair only if both are the same.`
      : `${prompt.peerName} is showing a code too. Pair only if both are the same.`;

  const confirm = () => {
    CrossDrop.feedback('confirm');
    onRespond(true);
  };

  return (
    <Stage
      mood="idle"
      onRequestClose={() => onRespond(false)}
      accessibilityLabel={`Pair with ${prompt.peerName}`}
    >
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        bounces={false}
      >
        <View style={styles.top}>
          <RoundButton
            icon="x"
            label="Cancel pairing"
            onPress={() => onRespond(false)}
          />
          <StatusPill label="New device" dot="#E0A100" />
          <View style={styles.spacer44} />
        </View>

        <View style={styles.art}>
          <Drip pose="pairing" size={art} motion="bob" />
        </View>

        <View style={styles.copy}>
          <Text variant="largeTitle" center accessibilityRole="header">
            Do these match?
          </Text>
          <Text variant="body" tone="secondary" center>
            {intro}
          </Text>
        </View>

        <View
          style={styles.codeCard}
          accessible
          accessibilityRole="text"
          accessibilityLabel={`Pairing code ${spokenPairingCode(
            prompt.code,
          )}. Expires in ${countdown(prompt.expiresAt - now)}`}
        >
          <Frost radius={32} />
          <CodeTiles
            code={prompt.code}
            onTick={() => CrossDrop.feedback('tick')}
          />
          <Text variant="footnote" tone="secondary" center>
            Expires in {countdown(prompt.expiresAt - now)}
          </Text>
        </View>

        <View style={styles.grow} />

        <View style={styles.actions}>
          {waiting ? (
            <View style={styles.waiting} accessibilityLiveRegion="polite">
              <ActivityIndicator color={t.link} />
              <Text variant="callout" tone="secondary">
                Waiting for {prompt.peerName} to confirm…
              </Text>
            </View>
          ) : (
            <Button title="Codes match" icon="check" large onPress={confirm} />
          )}
          <Button
            title={waiting ? 'Cancel pairing' : 'They don’t match'}
            kind="secondary"
            onPress={() => onRespond(false)}
          />
          <Text variant="footnote" tone="secondary" center>
            You only do this once per device.
          </Text>
        </View>
      </ScrollView>
    </Stage>
  );
}

const styles = StyleSheet.create({
  scroll: { flexGrow: 1 },
  top: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  spacer44: { width: 44 },
  art: { alignItems: 'center', marginTop: spacing.xs },
  copy: {
    gap: spacing.xs,
    marginTop: spacing.xs,
    paddingHorizontal: spacing.xs,
  },
  codeCard: {
    marginTop: spacing.xl,
    borderRadius: 32,
    overflow: 'hidden',
    paddingVertical: spacing.xl,
    paddingHorizontal: spacing.sm,
    gap: spacing.md,
    alignItems: 'center',
  },
  grow: { flexGrow: 1, minHeight: spacing.xl },
  actions: { gap: spacing.sm },
  waiting: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    minHeight: 58,
  },
});
