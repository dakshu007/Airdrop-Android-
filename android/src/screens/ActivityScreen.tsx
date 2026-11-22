import React, { useMemo, useState } from 'react';
import { Alert, Pressable, StyleSheet, TextInput, View } from 'react-native';
import { Button } from '../components/Button';
import { EmptyState } from '../components/EmptyState';
import { GlassCard } from '../components/GlassCard';
import { Icon, IconName } from '../components/Icon';
import { PocketRow, QueueRow } from '../components/PocketRows';
import { Screen } from '../components/Screen';
import { SectionHeader } from '../components/SectionHeader';
import { Text } from '../components/Text';
import { TransferCard } from '../components/TransferCard';
import { errorCode, friendlyError, isFinal } from '../copy';
import { deleteLabel, filesTitle, formatBytes, relativeTime } from '../format';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import type { HistoryEntry } from '../native/types';
import { useSnapshot } from '../state/CrossDropProvider';
import { useTheme } from '../theme/ThemeProvider';
import { minTouch, spacing } from '../theme/tokens';

const POCKET_PREVIEW = 4;

const STATUS_TEXT: Record<HistoryEntry['status'], string> = {
  completed: 'Completed',
  failed: 'Failed',
  cancelled: 'Cancelled',
  rejected: 'Not accepted',
};

function historyTitle(entry: HistoryEntry): string {
  if (entry.kind === 'link') return entry.link ?? 'Link';
  if (entry.kind === 'text') return 'Text';
  return filesTitle(entry.files);
}

async function sendAgain(entry: HistoryEntry) {
  try {
    await CrossDrop.resendHistory(entry.id);
  } catch (e) {
    const code = errorCode(e);
    Alert.alert(
      'Couldn’t send again',
      code === 'file_unreadable'
        ? 'Those files can no longer be read. Choose them again from Nearby.'
        : code === 'unreachable'
        ? `${entry.peerName} isn’t nearby right now.`
        : 'Something went wrong. Try again.',
    );
  }
}

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
  const expiry =
    entry.deleteAt !== null && entry.status === 'completed'
      ? deleteLabel(
          entry.deleteAt,
          now,
          entry.direction,
          outgoing ? entry.peerName : undefined,
          entry.deleted,
        )
      : null;
  const meta = `${outgoing ? 'To' : 'From'} ${entry.peerName} · ${formatBytes(
    entry.totalBytes,
  )} · ${relativeTime(entry.finishedAt, now)}${expiry ? ` · ${expiry}` : ''}`;

  const content = (
    <View style={styles.historyRow}>
      <View style={[styles.statusDot, { backgroundColor: t.track }]}>
        <Icon name={icon} size={18} color={color} strokeWidth={2.2} />
      </View>
      <View style={styles.flex}>
        <Text variant="callout" numberOfLines={1}>
          {historyTitle(entry)}
        </Text>
        <Text variant="footnote" tone="secondary" numberOfLines={2}>
          {statusText} · {meta}
        </Text>
      </View>
      {entry.canSendAgain ? (
        <Button
          title="Again"
          icon="refresh"
          kind="plain"
          compact
          onPress={() => sendAgain(entry)}
          accessibilityLabel={`Send ${historyTitle(entry)} to ${
            entry.peerName
          } again`}
        />
      ) : (
        <Icon
          name={outgoing ? 'arrowUp' : 'arrowDown'}
          size={18}
          color={t.textTertiary}
        />
      )}
    </View>
  );

  const label = `${historyTitle(entry)}. ${statusText}. ${meta}`;
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

  const { queue, pocket } = snapshot;
  const [allPocket, setAllPocket] = useState(false);
  const nothing =
    transfers.length === 0 &&
    snapshot.history.length === 0 &&
    queue.length === 0 &&
    pocket.length === 0;
  const [query, setQuery] = useState('');
  const t = useTheme();
  const history = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return snapshot.history;
    return snapshot.history.filter(
      h =>
        h.peerName.toLowerCase().includes(q) ||
        (h.link ?? '').toLowerCase().includes(q) ||
        h.files.some(f => f.name.toLowerCase().includes(q)),
    );
  }, [snapshot.history, query]);

  return (
    <Screen
      title="Activity"
      subtitle={
        active.length > 0
          ? `${active.length} in progress`
          : queue.length > 0
          ? `${queue.length} waiting to send`
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

      {queue.length > 0 ? (
        <>
          <SectionHeader title="Waiting to send" />
          <GlassCard padding={spacing.xs}>
            {queue.map((item, i) => (
              <View key={item.id}>
                {i > 0 ? (
                  <View
                    style={[styles.divider, { backgroundColor: t.hairline }]}
                  />
                ) : null}
                <QueueRow
                  item={item}
                  searching={snapshot.queueStorage.searching}
                />
              </View>
            ))}
          </GlassCard>
          <Text variant="footnote" tone="tertiary" style={styles.note}>
            Sent by themselves when the device is found: when CrossDrop opens,
            when Wi‑Fi reconnects, or while Nearby is open. No scanning in the
            background.
          </Text>
        </>
      ) : null}

      {pocket.length > 0 ? (
        <>
          <SectionHeader
            title="Pocket"
            trailing={
              pocket.length > POCKET_PREVIEW ? (
                <Button
                  title={allPocket ? 'Show less' : `Show all ${pocket.length}`}
                  kind="plain"
                  compact
                  onPress={() => setAllPocket(v => !v)}
                />
              ) : undefined
            }
          />
          <GlassCard padding={spacing.xs}>
            {(allPocket ? pocket : pocket.slice(0, POCKET_PREVIEW)).map(
              (item, i) => (
                <View key={item.id}>
                  {i > 0 ? (
                    <View
                      style={[styles.divider, { backgroundColor: t.hairline }]}
                    />
                  ) : null}
                  <PocketRow item={item} now={now} />
                </View>
              ),
            )}
          </GlassCard>
          <Text variant="footnote" tone="tertiary" style={styles.note}>
            Files you received lately, ready to open or pass on. Removing one
            here keeps the file unless you choose to delete it.
          </Text>
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
          {snapshot.history.length > 4 ? (
            <View style={[styles.search, { backgroundColor: t.glassFill }]}>
              <Icon name="search" size={18} color={t.textTertiary} />
              <TextInput
                value={query}
                onChangeText={setQuery}
                placeholder="Search files, links or devices"
                placeholderTextColor={t.textTertiary}
                style={[styles.searchInput, { color: t.textPrimary }]}
                accessibilityLabel="Search history"
                returnKeyType="search"
                autoCorrect={false}
              />
              {query ? (
                <Pressable
                  onPress={() => setQuery('')}
                  accessibilityRole="button"
                  accessibilityLabel="Clear search"
                  hitSlop={12}
                >
                  <Icon name="x" size={18} color={t.textTertiary} />
                </Pressable>
              ) : null}
            </View>
          ) : null}
          <GlassCard padding={spacing.xs}>
            {history.length === 0 ? (
              <Text
                variant="callout"
                tone="secondary"
                center
                style={styles.noMatch}
              >
                Nothing matches “{query.trim()}”
              </Text>
            ) : (
              history.map(entry => (
                <HistoryRow key={entry.id} entry={entry} now={now} />
              ))
            )}
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
  search: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    borderRadius: 16,
    paddingHorizontal: spacing.md,
    minHeight: minTouch,
    marginBottom: spacing.sm,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.9)',
  },
  searchInput: {
    flex: 1,
    fontFamily: 'Poppins-Regular',
    fontSize: 15,
    paddingVertical: 10,
  },
  noMatch: { paddingVertical: spacing.lg },
  divider: { height: 1, marginHorizontal: spacing.xs },
  note: { marginTop: spacing.xs, paddingHorizontal: spacing.xxs },
  statusDot: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
