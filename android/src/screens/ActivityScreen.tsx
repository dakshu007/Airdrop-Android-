import React from 'react';
import { Alert, Pressable, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { EmptyState } from '../components/EmptyState';
import { GlassCard } from '../components/GlassCard';
import { Icon, IconName } from '../components/Icon';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { TransferCard } from '../components/TransferCard';
import { friendlyError, isFinal } from '../copy';
import { filesTitle, formatBytes, relativeTime } from '../format';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import type { HistoryEntry } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, spacing } from '../theme/tokens';

const STATUS_TEXT: Record<HistoryEntry['status'], string> = {
  completed: 'Completed',
  failed: 'Failed',
  cancelled: 'Cancelled',
  rejected: 'Not accepted',
};

function HistoryRow({ entry, now }: { entry: HistoryEntry; now: number }) {
  const t = useTheme();
  const outgoing = entry.direction === 'outgoing';
  const icon: IconName =
    entry.status === 'completed'
      ? 'check'
      : entry.status === 'failed'
      ? 'alert'
      : 'x';
  const color =
    entry.status === 'completed'
      ? t.success
      : entry.status === 'failed'
      ? t.danger
      : t.textTertiary;
  const uris = entry.files.map(f => f.uri).filter((u): u is string => !!u);
  const openable = !outgoing && entry.status === 'completed' && uris.length > 0;
  const statusText =
    entry.status === 'failed' && entry.errorCode
      ? friendlyError(entry.errorCode).title
      : STATUS_TEXT[entry.status];
  const meta = `${outgoing ? 'To' : 'From'} ${entry.peerName} · ${formatBytes(
    entry.totalBytes,
  )} · ${relativeTime(entry.finishedAt, now)}`;

  const content = (
    <View style={styles.historyRow}>
      <View style={[styles.statusDot, { backgroundColor: t.track }]}>
        <Icon name={icon} size={18} color={color} strokeWidth={2.2} />
      </View>
      <View style={styles.flex}>
        <Text variant="callout" numberOfLines={1}>
          {filesTitle(entry.files)}
        </Text>
        <Text variant="footnote" tone="secondary" numberOfLines={2}>
          {statusText} · {meta}
        </Text>
      </View>
      <Icon
        name={outgoing ? 'arrowUp' : 'arrowDown'}
        size={18}
        color={t.textTertiary}
      />
    </View>
  );

  const label = `${filesTitle(entry.files)}. ${statusText}. ${meta}`;
  if (!openable) {
    return (
      <View accessible accessibilityLabel={label}>
        {content}
      </View>
    );
  }
  return (
    <Pressable
      onPress={() =>
        uris.length === 1
          ? CrossDrop.openFile(uris[0])
          : CrossDrop.openDownloads()
      }
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={
        uris.length === 1 ? 'Opens the file' : 'Opens the Downloads folder'
      }
      android_ripple={{ color: t.accentSoft }}
    >
      {content}
    </Pressable>
  );
}

export function ActivityScreen() {
  const snapshot = useSnapshot();
  const now = useNow(30000);
  const active = snapshot.transfers.filter(tr => !isFinal(tr.status));
  const finished = snapshot.transfers.filter(tr => isFinal(tr.status));
  const transfers = [...active, ...finished];

  const showError = (message: string) => Alert.alert('Couldn’t retry', message);

  const confirmClear = () =>
    Alert.alert(
      'Clear history?',
      'This removes the list of past transfers from this phone. Received files are kept.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Clear',
          style: 'destructive',
          onPress: () => CrossDrop.clearHistory(),
        },
      ],
    );

  const nothing = transfers.length === 0 && snapshot.history.length === 0;

  return (
    <Screen
      title="Activity"
      subtitle={
        active.length > 0
          ? `${active.length} in progress`
          : 'Transfers stay on this phone'
      }
    >
      {nothing ? (
        <GlassCard>
          <EmptyState
            icon="inbox"
            pose="welcome"
            title="No transfers yet"
            detail="Files you send or receive appear here. The history is stored only on this phone."
          />
        </GlassCard>
      ) : null}

      {transfers.length > 0 ? (
        <>
          <SectionHeader title="Now" />
          {transfers.map(tr => (
            <TransferCard key={tr.id} transfer={tr} onError={showError} />
          ))}
        </>
      ) : null}

      {snapshot.history.length > 0 ? (
        <>
          <SectionHeader
            title="History"
            trailing={
              <Button
                title="Clear"
                kind="plain"
                compact
                onPress={confirmClear}
                accessibilityLabel="Clear history"
              />
            }
          />
          <GlassCard padding={spacing.xs}>
            {snapshot.history.map(entry => (
              <HistoryRow key={entry.id} entry={entry} now={now} />
            ))}
          </GlassCard>
        </>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  historyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: minTouch + 8,
    paddingHorizontal: spacing.xs,
    paddingVertical: spacing.xs,
  },
  statusDot: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
