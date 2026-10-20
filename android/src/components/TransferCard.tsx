import React from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { friendlyError, isFinal, rejectReason, statusLabel } from '../copy';
import {
  etaSeconds,
  filesTitle,
  formatBytes,
  formatEta,
  formatRate,
  pluralFiles,
} from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { Transfer } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { radii, spacing } from '../theme/tokens';
import { Button } from './Button';
import { GlassCard } from './GlassCard';
import { IconBubble } from './IconBubble';
import { ProgressBar } from './ProgressBar';
import { Text } from './Text';

const WAITING = new Set([
  'preparing',
  'connecting',
  'pairing',
  'waitingForAcceptance',
  'awaitingYourApproval',
]);

export function TransferCard({
  transfer,
  onError,
}: {
  transfer: Transfer;
  onError: (message: string) => void;
}) {
  const t = useTheme();
  const outgoing = transfer.direction === 'outgoing';
  const final = isFinal(transfer.status);
  const fraction =
    transfer.totalBytes > 0
      ? transfer.bytesTransferred / transfer.totalBytes
      : final
      ? 1
      : 0;
  const peerLine = outgoing
    ? `To ${transfer.peerName}`
    : `From ${transfer.peerName}`;

  const statusTone =
    transfer.status === 'completed'
      ? 'success'
      : transfer.status === 'failed'
      ? 'danger'
      : transfer.status === 'transferring'
      ? 'accent'
      : 'secondary';

  const elapsedMs = transfer.updatedAt - transfer.startedAt;
  const eta =
    transfer.status === 'transferring' && elapsedMs > 3000
      ? etaSeconds(
          transfer.totalBytes - transfer.bytesTransferred,
          transfer.bytesPerSecond,
        )
      : null;

  const progressParts = [
    `${formatBytes(transfer.bytesTransferred)} of ${formatBytes(
      transfer.totalBytes,
    )}`,
  ];
  if (transfer.status === 'transferring' && transfer.bytesPerSecond !== null) {
    progressParts.push(formatRate(transfer.bytesPerSecond));
  }
  if (eta !== null) {
    progressParts.push(formatEta(eta));
  }

  const savedUris = transfer.files
    .map(f => f.uri)
    .filter((u): u is string => !!u);
  const error =
    transfer.status === 'failed' ? friendlyError(transfer.error?.code) : null;

  const retry = async () => {
    try {
      await CrossDrop.retryTransfer(transfer.id);
    } catch (e) {
      onError(
        e instanceof Error ? e.message : 'Could not retry this transfer.',
      );
    }
  };

  return (
    <GlassCard radius={radii.md} style={styles.card}>
      <View style={styles.header}>
        <IconBubble
          name={outgoing ? 'arrowUp' : 'arrowDown'}
          size={44}
          color={transfer.status === 'failed' ? t.danger : undefined}
          background={transfer.status === 'failed' ? t.dangerSoft : undefined}
        />
        <View style={styles.headerText}>
          <Text variant="headline" numberOfLines={2}>
            {filesTitle(transfer.files)}
          </Text>
          <Text variant="footnote" tone="secondary" numberOfLines={1}>
            {peerLine} · {pluralFiles(transfer.files.length)} ·{' '}
            {formatBytes(transfer.totalBytes)}
          </Text>
        </View>
      </View>

      <View style={styles.status}>
        {WAITING.has(transfer.status) ? (
          <ActivityIndicator size="small" color={t.textSecondary} />
        ) : null}
        <Text variant="subhead" tone={statusTone}>
          {statusLabel(transfer.status, transfer.direction)}
        </Text>
      </View>

      {transfer.status === 'transferring' ||
      (final &&
        transfer.bytesTransferred > 0 &&
        transfer.status !== 'completed') ? (
        <View style={styles.progress}>
          <ProgressBar
            value={fraction}
            color={transfer.status === 'failed' ? t.danger : undefined}
            accessibilityLabel={`${
              outgoing ? 'Sending' : 'Receiving'
            } progress`}
          />
          <Text variant="footnote" tone="secondary">
            {progressParts.join(' · ')}
          </Text>
        </View>
      ) : null}

      {error ? (
        <View style={styles.detail}>
          <Text variant="subhead" tone="danger">
            {error.title}
          </Text>
          <Text variant="footnote" tone="secondary">
            {error.detail}
          </Text>
        </View>
      ) : null}
      {transfer.status === 'rejected' ? (
        <Text variant="footnote" tone="secondary" style={styles.detail}>
          {rejectReason(transfer.rejectReason)}
        </Text>
      ) : null}

      <View style={styles.actions}>
        {!final ? (
          <Button
            title="Cancel"
            kind="secondary"
            compact
            icon="x"
            onPress={() => CrossDrop.cancelTransfer(transfer.id)}
            accessibilityLabel={`Cancel transfer ${filesTitle(transfer.files)}`}
          />
        ) : null}
        {transfer.canRetry ? (
          <Button title="Retry" compact icon="refresh" onPress={retry} />
        ) : null}
        {!outgoing &&
        transfer.status === 'completed' &&
        savedUris.length === 1 ? (
          <Button
            title="Open"
            compact
            onPress={() => CrossDrop.openFile(savedUris[0])}
          />
        ) : null}
        {!outgoing &&
        transfer.status === 'completed' &&
        savedUris.length !== 1 ? (
          <Button
            title="Show in Downloads"
            compact
            icon="folder"
            onPress={() => CrossDrop.openDownloads()}
          />
        ) : null}
        {final ? (
          <Button
            title="Dismiss"
            kind="plain"
            compact
            onPress={() => CrossDrop.dismissTransfer(transfer.id)}
            accessibilityLabel={`Dismiss ${filesTitle(transfer.files)}`}
          />
        ) : null}
      </View>
    </GlassCard>
  );
}

const styles = StyleSheet.create({
  card: { marginBottom: spacing.sm },
  header: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  headerText: { flex: 1 },
  status: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    marginTop: spacing.sm,
  },
  progress: { gap: spacing.xs, marginTop: spacing.sm },
  detail: { marginTop: spacing.xs, gap: 2 },
  actions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    marginTop: spacing.md,
  },
});
