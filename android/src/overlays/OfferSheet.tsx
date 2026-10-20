import React from 'react';
import { StyleSheet, View } from 'react-native';
import { Badge } from '../components/Badge';
import { Button } from '../components/Button';
import { FileRow } from '../components/FileRow';
import { IconBubble } from '../components/IconBubble';
import { Text } from '../components/Text';
import { platformLabel } from '../copy';
import { countdown, formatBytes, pluralFiles } from '../format';
import type { IncomingOffer } from '../native/types';
import { spacing } from '../theme/tokens';

const PREVIEW = 5;

interface Props {
  offer: IncomingOffer;
  trusted: boolean;
  now: number;
  responded: boolean;
  onRespond: (accept: boolean) => void;
}

export function OfferSheetContent({
  offer,
  trusted,
  now,
  responded,
  onRespond,
}: Props) {
  return (
    <>
      <View style={styles.header}>
        <IconBubble
          name={offer.peerPlatform === 'macos' ? 'laptop' : 'phone'}
          size={56}
        />
        <Text variant="title" center accessibilityRole="header">
          {offer.peerName} wants to send {pluralFiles(offer.files.length)}
        </Text>
        <View style={styles.badges}>
          <Badge label={platformLabel(offer.peerPlatform)} />
          {trusted ? (
            <Badge label="Paired" tone="success" icon="shieldCheck" />
          ) : (
            <Badge label="Not paired" tone="warning" icon="shield" />
          )}
        </View>
      </View>

      <View>
        {offer.files.slice(0, PREVIEW).map((f, i) => (
          <FileRow
            key={`${i}-${f.name}`}
            name={f.name}
            size={f.size}
            mime={f.mime}
          />
        ))}
        {offer.files.length > PREVIEW ? (
          <Text variant="footnote" tone="tertiary">
            and {offer.files.length - PREVIEW} more
          </Text>
        ) : null}
      </View>

      <Text variant="headline" center>
        Total {formatBytes(offer.totalBytes)}
      </Text>
      <Text variant="footnote" tone="secondary" center>
        Only accept files you expect. They’ll be checked and saved to your
        Downloads.
      </Text>

      <Button
        title="Accept"
        icon="download"
        loading={responded}
        onPress={() => onRespond(true)}
      />
      <Button
        title="Decline"
        kind="secondary"
        disabled={responded}
        onPress={() => onRespond(false)}
      />
      <Text variant="footnote" tone="tertiary" center>
        Expires in {countdown(offer.expiresAt - now)}
      </Text>
    </>
  );
}

const styles = StyleSheet.create({
  header: { alignItems: 'center', gap: spacing.xs },
  badges: {
    flexDirection: 'row',
    gap: spacing.xs,
    justifyContent: 'center',
    flexWrap: 'wrap',
  },
});
