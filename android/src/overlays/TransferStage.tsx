import React, { useEffect, useRef, useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { RoundButton, StatusPill } from '../components/Chips';
import { Confetti } from '../components/Confetti';
import { Drip } from '../components/Drip';
import { Frost } from '../components/Frost';
import { ProgressRing } from '../components/ProgressRing';
import { Stage, useArtSize } from '../components/Stage';
import { Text } from '../components/Text';
import {
  errorCode,
  friendlyError,
  isFinal,
  queueError,
  rejectReason,
} from '../copy';
import {
  deleteLabel,
  etaSeconds,
  filesTitle,
  formatBytes,
  formatEtaShort,
  formatRate,
  pluralFiles,
} from '../format';
import { Icon } from '../components/Icon';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import type { Transfer } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { recallSend } from '../state/sendMemory';
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

/** Errors after which the device simply wasn't there: worth offering "Send when nearby". */
const QUEUED_LINGER_MS = 1800;
const NOT_THERE = new Set([
  'unreachable',
  'connection_lost',
  'timeout',
  'not_receiving',
]);

/**
 * "Send when nearby" for a failed send to a paired device: the files this app
 * session handed over are queued, so they go by themselves when it's back.
 */
function SendLater({ transfer }: { transfer: Transfer }) {
  const t = useTheme();
  const snapshot = useSnapshot();
  const [state, setState] = useState<'idle' | 'busy' | 'queued'>('idle');
  const [error, setError] = useState<string | null>(null);
  const remembered = recallSend(transfer.id);
  const paired = snapshot.trusted.some(d => d.deviceId === transfer.peerId);
  // Once queued, the failed attempt is cleared after a moment to read the confirmation.
  useEffect(() => {
    if (state !== 'queued') return;
    const timer = setTimeout(
      () => CrossDrop.dismissTransfer(transfer.id),
      QUEUED_LINGER_MS,
    );
    return () => clearTimeout(timer);
  }, [state, transfer.id]);
  if (
    transfer.direction !== 'outgoing' ||
    transfer.kind !== 'files' ||
    transfer.status !== 'failed' ||
    !NOT_THERE.has(transfer.error?.code ?? '') ||
    !paired ||
    !remembered
  ) {
    return null;
  }
  if (state === 'queued') {
    return (
      <View
        style={styles.queued}
        accessible
        accessibilityLiveRegion="polite"
        accessibilityLabel={`Waiting for ${transfer.peerName}. It goes by itself when it’s nearby.`}
      >
        <Icon name="clock" size={18} color={t.link} />
        <Text variant="callout" tone="accent" style={styles.flex}>
          Waiting for {transfer.peerName} · goes by itself when it’s nearby
        </Text>
      </View>
    );
  }
  const queue = async () => {
    setState('busy');
    setError(null);
    try {
      await CrossDrop.queueFiles(
        remembered.deviceId,
        remembered.files,
        remembered.options,
      );
      CrossDrop.feedback('confirm');
      setState('queued');
    } catch (e) {
      setError(queueError(errorCode(e)));
      setState('idle');
    }
  };
  return (
    <>
      <Button
        title="Send when nearby"
        icon="clock"
        kind={transfer.canRetry ? 'secondary' : 'primary'}
        large={!transfer.canRetry}
        loading={state === 'busy'}
        onPress={queue}
        accessibilityHint={`Sends these files to ${transfer.peerName} by itself when it is found`}
      />
      {error ? (
        <Text variant="footnote" tone="danger" center>
          {error}
        </Text>
      ) : null}
    </>
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
  const now = useNow(60000, transfer.deleteAt !== null);
  const expiry =
    transfer.deleteAt !== null
      ? deleteLabel(
          transfer.deleteAt,
          now,
          transfer.direction,
          outgoing ? peer : undefined,
        )
      : null;
  const photo = transfer.answersCapture && outgoing;

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

  if (transfer.status === 'completed' && transfer.kind !== 'files') {
    mood = 'done';
    const link = transfer.kind === 'link';
    const text = transfer.text;
    const webLink = link && !!text && /^https?:\/\/\S+$/i.test(text.trim());
    const sentDetail =
      transfer.peerPlatform === 'macos'
        ? link
          ? `It opened on ${peer}.`
          : `It’s on ${peer}’s clipboard.`
        : `${peer} can open it from the notification.`;
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
            {outgoing
              ? link
                ? 'Link sent'
                : 'Text sent'
              : link
              ? `Link from ${peer}`
              : `Text from ${peer}`}
          </Text>
          <Text variant="body" tone="secondary" center>
            {outgoing
              ? sentDetail
              : 'Nothing was opened or saved. Choose what to do with it.'}
          </Text>
        </View>
        <View style={styles.center}>
          <Drip pose="done" size={art * 0.8} motion="pop" />
        </View>
        {text ? (
          <View style={styles.summary}>
            <Frost radius={20} />
            <Text
              variant={link ? 'subhead' : 'body'}
              numberOfLines={link ? 3 : 8}
              selectable
              accessibilityLabel={link ? `Link ${text}` : `Text ${text}`}
            >
              {text}
            </Text>
          </View>
        ) : null}
        <View style={styles.actions}>
          {!outgoing && webLink ? (
            <Button
              title="Open link"
              icon="arrowUpRight"
              large
              onPress={() => CrossDrop.openLink(text!.trim())}
            />
          ) : null}
          {!outgoing && text ? (
            <Button
              title="Copy"
              kind={webLink ? 'secondary' : 'primary'}
              large={!webLink}
              onPress={() => CrossDrop.copyText(text)}
            />
          ) : null}
          {outgoing ? (
            <Button title="Send more" icon="plus" large onPress={onSendMore} />
          ) : null}
          <Button title="Done" kind="plain" onPress={onClose} />
        </View>
      </>
    );
  } else if (transfer.status === 'completed') {
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
            {photo ? 'Photo delivered' : 'All done!'}
          </Text>
          <Text variant="body" tone="secondary" center>
            {outgoing
              ? `${
                  photo
                    ? transfer.files.length === 1
                      ? 'Your photo'
                      : `${transfer.files.length} photos`
                    : pluralFiles(transfer.files.length)
                } arrived on ${peer} and passed the integrity check.`
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
        {expiry ? (
          <View style={styles.expiry} accessible accessibilityLabel={expiry}>
            <Icon name="clock" size={15} color="#8A5A00" />
            <Text variant="footnote" tone="warning">
              {expiry}
            </Text>
          </View>
        ) : null}
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
          <SendLater transfer={transfer} />
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
          <StatusPill
            label={
              transfer.streams > 1
                ? `${status} · Turbo ×${transfer.streams}`
                : status
            }
            dot={moving ? '#149A5B' : '#E0A100'}
          />
          <Text variant="largeTitle" center accessibilityRole="header">
            {outgoing ? `Sending to ${peer}` : `Receiving from ${peer}`}
          </Text>
          <Text variant="body" tone="secondary" center numberOfLines={2}>
            {photo
              ? `Your answer to ${peer}’s photo request`
              : filesTitle(transfer.files)}
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
  expiry: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  queued: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    justifyContent: 'center',
    minHeight: 48,
  },
});
