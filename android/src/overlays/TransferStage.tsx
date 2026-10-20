import React, { useEffect, useRef } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { RoundButton, StatusPill } from '../components/Chips';
import { Confetti } from '../components/Confetti';
import { Drip } from '../components/Drip';
import { Frost } from '../components/Frost';
import { ProgressRing } from '../components/ProgressRing';
import { Stage, useArtSize } from '../components/Stage';
import { Text } from '../components/Text';
import { friendlyError, isFinal, rejectReason } from '../copy';
import {
  etaSeconds,
  filesTitle,
  formatBytes,
  formatEtaShort,
  formatRate,
  pluralFiles,
} from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { Transfer } from '../native/types';
import type { Mood } from '../theme/Backdrop';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

interface Props {
  transfer: Transfer;
  /** Leave the stage while the transfer keeps going (it stays in Activity). */
  onHide: () => void;
  /** Close after a finished transfer. */
  onClose: () => void;
  /** Close and go back to Nearby to pick more files. */
  onSendMore: () => void;
  onRetryError: (message: string) => void;
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <View
      style={styles.stat}
      accessible
      accessibilityLabel={`${value} ${label}`}
    >
      <Frost radius={18} />
      <Text
        variant="headline"
        mono
        numberOfLines={1}
        adjustsFontSizeToFit
        style={styles.statValue}
      >
        {value}
      </Text>
      <Text variant="footnote" tone="secondary" numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

function FilesCard({
  transfer,
  limit = 3,
}: {
  transfer: Transfer;
  limit?: number;
}) {
  const t = useTheme();
  return (
    <View style={styles.filesCard}>
      <Frost radius={22} />
      {transfer.files.slice(0, limit).map((f, i) => (
        <View key={`${i}-${f.name}`}>
          {i > 0 ? (
            <View style={[styles.hairline, { backgroundColor: t.hairline }]} />
          ) : null}
          <View style={styles.fileLine}>
            <Text variant="subhead" numberOfLines={1} style={styles.flex}>
              {f.name}
            </Text>
            <Text variant="footnote" tone="secondary">
              {formatBytes(f.size)}
            </Text>
          </View>
        </View>
      ))}
      {transfer.files.length > limit ? (
        <Text variant="footnote" tone="secondary" style={styles.more}>
          and {transfer.files.length - limit} more
        </Text>
      ) : null}
    </View>
  );
}

/** Sending or receiving, then the result: progress ring, all-done confetti, or what went wrong. */
export function TransferStage({
  transfer,
  onHide,
  onClose,
  onSendMore,
  onRetryError,
}: Props) {
  const ring = useArtSize(0.3, 250, 170);
  const art = useArtSize(0.34, 300, 160);
  const outgoing = transfer.direction === 'outgoing';
  const final = isFinal(transfer.status);
  const peer = transfer.peerName;

  // Haptics (and the optional sound) when the transfer ends while it's on screen.
  const previous = useRef(transfer.status);
  useEffect(() => {
    if (previous.current === transfer.status) return;
    previous.current = transfer.status;
    if (transfer.status === 'completed') CrossDrop.feedback('done');
    else if (transfer.status === 'failed' || transfer.status === 'rejected')
      CrossDrop.feedback('error');
  }, [transfer.status]);

  const retry = async () => {
    try {
      // The new attempt is a new transfer; Overlays follows it automatically.
      await CrossDrop.retryTransfer(transfer.id);
    } catch (e) {
      onRetryError(
        e instanceof Error ? e.message : 'Could not retry this transfer.',
      );
    }
  };

  let mood: Mood = 'active';
  let body: React.ReactNode;

  if (transfer.status === 'completed') {
    mood = 'done';
    const uris = transfer.files.map(f => f.uri).filter((u): u is string => !!u);
    body = (
      <>
        <View style={styles.head}>
          <StatusPill label="Verified" />
          <Text
            variant="display"
            center
            accessibilityRole="header"
            accessibilityLiveRegion="polite"
          >
            All done!
          </Text>
          <Text variant="body" tone="secondary" center>
            {outgoing
              ? `${pluralFiles(
                  transfer.files.length,
                )} arrived on ${peer} and passed the integrity check.`
              : `${pluralFiles(
                  transfer.files.length,
                )} from ${peer} saved and passed the integrity check.`}
          </Text>
        </View>
        <View style={styles.center}>
          <Confetti />
          <Drip pose="done" size={art} motion="pop" />
        </View>
        <FilesCard transfer={transfer} />
        <View style={styles.actions}>
          {outgoing ? (
            <>
              <Button
                title="Send more"
                icon="plus"
                large
                onPress={onSendMore}
              />
              <Button title="Done" kind="plain" onPress={onClose} />
            </>
          ) : (
            <>
              {uris.length === 1 ? (
                <Button
                  title="Open"
                  large
                  onPress={() => CrossDrop.openFile(uris[0])}
                />
              ) : (
                <Button
                  title="Show in Downloads"
                  icon="folder"
                  large
                  onPress={() => CrossDrop.openDownloads()}
                />
              )}
              <Button title="Done" kind="secondary" onPress={onClose} />
            </>
          )}
        </View>
      </>
    );
  } else if (final) {
    mood = 'failed';
    const rejected = transfer.status === 'rejected';
    const cancelled = transfer.status === 'cancelled';
    const error = friendlyError(transfer.error?.code);
    const reached =
      transfer.totalBytes > 0
        ? Math.round((transfer.bytesTransferred / transfer.totalBytes) * 100)
        : 0;
    const title = rejected
      ? 'Not accepted'
      : cancelled
      ? 'Cancelled'
      : 'That didn’t go through';
    const detail = rejected
      ? rejectReason(transfer.rejectReason)
      : cancelled
      ? 'The transfer was stopped. Nothing incomplete was kept.'
      : error.detail;
    body = (
      <>
        <View style={styles.head}>
          <StatusPill
            label={outgoing ? 'Not sent' : 'Not received'}
            dot="#C9573B"
          />
          <Text
            variant="largeTitle"
            center
            accessibilityRole="header"
            accessibilityLiveRegion="polite"
          >
            {title}
          </Text>
          <Text variant="body" tone="secondary" center>
            {detail}
          </Text>
        </View>
        <View style={styles.center}>
          <Drip pose="failed" size={art * 0.92} motion="wobble" />
        </View>
        <View style={styles.summary}>
          <Frost radius={20} />
          <Text variant="headline" numberOfLines={1}>
            {filesTitle(transfer.files)} · {formatBytes(transfer.totalBytes)}
          </Text>
          <Text variant="footnote" tone="secondary">
            {rejected || cancelled
              ? `${outgoing ? 'To' : 'From'} ${peer}`
              : `${reached > 0 ? `Stopped at ${reached}% · ` : ''}${
                  error.title
                }`}
          </Text>
        </View>
        <View style={styles.actions}>
          {transfer.canRetry ? (
            <Button title="Try again" icon="refresh" large onPress={retry} />
          ) : null}
          <Button title="Not now" kind="secondary" onPress={onClose} />
        </View>
      </>
    );
  } else {
    const moving = transfer.status === 'transferring';
    mood = moving ? 'active' : 'idle';
    const fraction =
      transfer.totalBytes > 0
        ? transfer.bytesTransferred / transfer.totalBytes
        : 0;
    const status =
      {
        preparing: 'Getting files ready',
        connecting: 'Connecting',
        pairing: 'Confirming the code',
        waitingForAcceptance: `Waiting for ${peer} to accept`,
        awaitingYourApproval: 'Waiting for you',
        transferring: 'Connected · encrypted',
      }[transfer.status as string] ?? 'Connecting';
    const elapsed = transfer.updatedAt - transfer.startedAt;
    const eta =
      moving && elapsed > 3000
        ? etaSeconds(
            transfer.totalBytes - transfer.bytesTransferred,
            transfer.bytesPerSecond,
          )
        : null;
    body = (
      <>
        <View style={styles.topRow}>
          <RoundButton
            icon="chevronDown"
            label="Hide. The transfer continues in Activity"
            onPress={onHide}
          />
        </View>
        <View style={styles.head}>
          <StatusPill label={status} dot={moving ? '#149A5B' : '#E0A100'} />
          <Text variant="largeTitle" center accessibilityRole="header">
            {outgoing ? `Sending to ${peer}` : `Receiving from ${peer}`}
          </Text>
          <Text variant="body" tone="secondary" center numberOfLines={2}>
            {filesTitle(transfer.files)}
          </Text>
        </View>
        <View style={styles.center}>
          <ProgressRing
            value={moving ? fraction : null}
            size={ring}
            sheen={moving}
            accessibilityLabel={
              outgoing ? 'Sending progress' : 'Receiving progress'
            }
          >
            <View style={{ marginTop: -ring * 0.16 }}>
              <Drip pose="sending" size={ring * 0.92} motion="float" />
            </View>
            <Text
              variant="title"
              mono
              style={[styles.percent, { bottom: ring * 0.13 }]}
            >
              {moving ? `${Math.round(fraction * 100)}%` : '…'}
            </Text>
          </ProgressRing>
        </View>
        {moving ? (
          <View style={styles.stats}>
            <Stat
              value={formatBytes(transfer.bytesTransferred)}
              label={`of ${formatBytes(transfer.totalBytes)}`}
            />
            <Stat
              value={
                transfer.bytesPerSecond !== null
                  ? formatRate(transfer.bytesPerSecond)
                  : '—'
              }
              label="speed"
            />
            <Stat
              value={eta !== null ? formatEtaShort(eta) : '—'}
              label="left"
            />
          </View>
        ) : (
          <Text
            variant="callout"
            tone="secondary"
            center
            style={styles.waitNote}
          >
            {transfer.status === 'waitingForAcceptance'
              ? `${peer} needs to tap Accept.`
              : 'Setting up an encrypted connection.'}
          </Text>
        )}
        <View style={styles.actions}>
          <Button
            title="Cancel"
            kind="secondary"
            icon="x"
            onPress={() => CrossDrop.cancelTransfer(transfer.id)}
            accessibilityLabel={`Cancel ${
              outgoing ? 'sending' : 'receiving'
            } ${filesTitle(transfer.files)}`}
          />
        </View>
      </>
    );
  }

  return (
    <Stage
      mood={mood}
      onRequestClose={final ? onClose : onHide}
      accessibilityLabel={
        outgoing ? `Transfer to ${peer}` : `Transfer from ${peer}`
      }
    >
      <ScrollView
        contentContainerStyle={styles.scroll}
        showsVerticalScrollIndicator={false}
        bounces={false}
      >
        {body}
      </ScrollView>
    </Stage>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  scroll: { flexGrow: 1, gap: spacing.md },
  topRow: { flexDirection: 'row' },
  head: {
    alignItems: 'center',
    gap: spacing.xs,
    marginTop: spacing.md,
    paddingHorizontal: spacing.xs,
  },
  center: {
    flexGrow: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 160,
  },
  percent: { position: 'absolute', left: 0, right: 0, textAlign: 'center' },
  stats: { flexDirection: 'row', gap: 10 },
  stat: {
    flex: 1,
    alignItems: 'center',
    gap: 2,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.xs,
    borderRadius: 18,
    overflow: 'hidden',
  },
  statValue: { fontSize: 15 },
  waitNote: { paddingHorizontal: spacing.md },
  filesCard: {
    borderRadius: 22,
    overflow: 'hidden',
    paddingHorizontal: 14,
    paddingVertical: 6,
  },
  fileLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingVertical: spacing.xs,
  },
  hairline: { height: 1 },
  more: { paddingVertical: spacing.xs },
  summary: { borderRadius: 20, overflow: 'hidden', padding: 14, gap: 2 },
  actions: { gap: spacing.sm, marginTop: spacing.xs },
});
