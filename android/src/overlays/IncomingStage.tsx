import React from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { StatusPill } from '../components/Chips';
import { Drip } from '../components/Drip';
import { FileRow } from '../components/FileRow';
import { Frost } from '../components/Frost';
import { Icon } from '../components/Icon';
import { Stage, useArtSize } from '../components/Stage';
import { Text } from '../components/Text';
import { countdown, formatBytes, pluralFiles } from '../format';
import type { IncomingOffer } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

const PREVIEW = 4;

interface Props {
  offer: IncomingOffer;
  trusted: boolean;
  destination: string;
  now: number;
  responded: boolean;
  onRespond: (accept: boolean) => void;
}

/** Someone wants to send files: Drip pops out of a parcel above a glass sheet. */
export function IncomingStage({
  offer,
  trusted,
  destination,
  now,
  responded,
  onRespond,
}: Props) {
  const t = useTheme();
  const art = useArtSize(0.28, 250, 150);
  return (
    <Stage
      mood="incoming"
      onRequestClose={() => onRespond(false)}
      accessibilityLabel={`Incoming files from ${offer.peerName}`}
    >
      <View style={styles.head}>
        {trusted ? (
          <StatusPill label="Paired device" />
        ) : (
          <StatusPill label="Not paired" dot="#E0A100" />
        )}
        <Text
          variant="title"
          center
          accessibilityRole="header"
          style={styles.title}
        >
          Files are on their way
        </Text>
      </View>

      <View style={styles.art}>
        <Drip pose="incoming" size={art} motion="pop" />
      </View>

      <View style={[styles.sheet, { marginTop: -art * 0.18 }]}>
        <Frost radius={36} tint="rgba(255,255,255,0.8)" />
        <ScrollView
          contentContainerStyle={styles.sheetContent}
          showsVerticalScrollIndicator={false}
        >
          <View style={styles.who}>
            <Text variant="headline" center style={styles.peer}>
              {offer.peerName}
            </Text>
            <Text variant="callout" tone="secondary" center>
              wants to send {pluralFiles(offer.files.length)} ·{' '}
              {formatBytes(offer.totalBytes)}
            </Text>
          </View>

          <View style={styles.files}>
            {offer.files.slice(0, PREVIEW).map((f, i) => (
              <View
                key={`${i}-${f.name}`}
                style={[styles.fileRow, { backgroundColor: t.inset }]}
              >
                <FileRow name={f.name} size={f.size} mime={f.mime} />
              </View>
            ))}
            {offer.files.length > PREVIEW ? (
              <Text variant="footnote" tone="secondary" center>
                and {offer.files.length - PREVIEW} more
              </Text>
            ) : null}
          </View>

          <View style={styles.note}>
            <Icon name="shieldCheck" size={15} color={t.link} />
            <Text
              variant="footnote"
              tone="secondary"
              center
              style={styles.noteText}
            >
              Checked on arrival, saved to {destination}
            </Text>
          </View>
        </ScrollView>

        <View style={styles.buttons}>
          <Button
            title="Decline"
            kind="secondary"
            disabled={responded}
            onPress={() => onRespond(false)}
            style={styles.decline}
          />
          <Button
            title="Accept"
            icon="download"
            large
            loading={responded}
            onPress={() => onRespond(true)}
            style={styles.accept}
          />
        </View>
        <Text variant="footnote" tone="tertiary" center style={styles.expires}>
          Only accept files you expect · expires in{' '}
          {countdown(offer.expiresAt - now)}
        </Text>
      </View>
    </Stage>
  );
}

const styles = StyleSheet.create({
  head: { alignItems: 'center', gap: spacing.sm, marginTop: spacing.sm },
  title: { marginTop: spacing.xxs },
  art: { alignItems: 'center', zIndex: 2 },
  sheet: {
    flex: 1,
    marginHorizontal: -spacing.sm,
    borderRadius: 36,
    overflow: 'hidden',
    paddingTop: spacing.xxl,
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.md,
  },
  sheetContent: { gap: spacing.md, paddingBottom: spacing.sm },
  who: { gap: 2 },
  peer: { fontSize: 17 },
  files: { gap: spacing.xs },
  fileRow: { borderRadius: 18, paddingHorizontal: spacing.sm },
  note: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  noteText: { flexShrink: 1 },
  buttons: { flexDirection: 'row', gap: 10, marginTop: spacing.sm },
  decline: { flex: 1 },
  accept: { flex: 1.4 },
  expires: { marginTop: spacing.sm },
});
