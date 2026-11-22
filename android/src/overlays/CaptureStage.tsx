import React, { useState } from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { Button } from '../components/Button';
import { StatusPill } from '../components/Chips';
import { Frost } from '../components/Frost';
import { Icon } from '../components/Icon';
import { Ripple } from '../components/Ripple';
import { Stage, useArtSize } from '../components/Stage';
import { Text } from '../components/Text';
import { errorCode } from '../copy';
import { countdownCoarse } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type { CaptureRequestInfo } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

interface Props {
  request: CaptureRequestInfo;
  now: number;
  /** "Not now": the request is forgotten here (the Mac isn't told). */
  onDecline: () => void;
  /** The request ended while open (expired or answered elsewhere). */
  onGone: () => void;
}

/**
 * A paired Mac asks this phone for a photo: take one now or pick existing
 * ones, and it goes straight back. The camera and the photo picker are the
 * system's; the photo isn't added to the gallery.
 */
export function CaptureStage({ request, now, onDecline, onGone }: Props) {
  const t = useTheme();
  const art = useArtSize(0.3, 230, 150);
  const [busy, setBusy] = useState<'photo' | 'pick' | null>(null);
  const peer = request.peerName;
  const wantsPick = request.kind === 'pick';

  const start = async (mode: 'photo' | 'pick') => {
    setBusy(mode);
    try {
      const opened = await CrossDrop.startCapture(request.requestId, mode);
      if (!opened) {
        Alert.alert(
          mode === 'photo' ? 'No camera app found' : 'No photo picker found',
          mode === 'photo'
            ? 'Choose an existing photo instead.'
            : 'Take a new photo instead.',
        );
      }
    } catch (e) {
      const code = errorCode(e);
      if (code === 'expired') {
        Alert.alert(
          'That request has ended',
          `Ask again from ${peer} if you still want to send a photo.`,
        );
        onGone();
      } else if (code !== 'no_activity') {
        Alert.alert('Couldn’t open the camera', 'Try again.');
      }
    } finally {
      setBusy(null);
    }
  };

  const take = (
    <Button
      key="photo"
      title="Take photo"
      icon="camera"
      large={!wantsPick}
      kind={wantsPick ? 'secondary' : 'primary'}
      loading={busy === 'photo'}
      disabled={busy !== null}
      onPress={() => start('photo')}
      accessibilityHint={`Opens the camera. The photo goes to ${peer}`}
    />
  );
  const pick = (
    <Button
      key="pick"
      title={wantsPick ? 'Pick photos' : 'Pick photo'}
      icon="image"
      large={wantsPick}
      kind={wantsPick ? 'primary' : 'secondary'}
      loading={busy === 'pick'}
      disabled={busy !== null}
      onPress={() => start('pick')}
      accessibilityHint={`Opens the photo picker. What you choose goes to ${peer}`}
    />
  );

  return (
    <Stage
      mood="incoming"
      onRequestClose={onDecline}
      accessibilityLabel={`${peer} asks for a photo`}
    >
      <View style={styles.head}>
        <StatusPill label={`Paired · ${peer}`} />
        <Text
          variant="largeTitle"
          center
          accessibilityRole="header"
          accessibilityLiveRegion="polite"
        >
          {wantsPick ? `${peer} wants photos` : `${peer} wants a photo`}
        </Text>
        <Text variant="body" tone="secondary" center>
          {wantsPick
            ? `Choose photos or videos and they go straight to ${peer}, encrypted over your Wi‑Fi. CrossDrop only sees the ones you pick.`
            : `Take one now and it goes straight to ${peer}, encrypted over your Wi‑Fi. It isn’t added to your gallery.`}
        </Text>
      </View>

      <View style={styles.art}>
        <Ripple size={art} rings={3} duration={2600}>
          <View
            style={[
              styles.disc,
              {
                width: art * 0.48,
                height: art * 0.48,
                borderRadius: art * 0.24,
              },
            ]}
          >
            <Frost radius={art * 0.24} tint="rgba(255,255,255,0.88)" />
            <Icon
              name={wantsPick ? 'image' : 'camera'}
              size={Math.round(art * 0.2)}
              color={t.link}
              strokeWidth={1.6}
            />
          </View>
        </Ripple>
      </View>

      <View style={styles.actions}>
        {wantsPick ? [pick, take] : [take, pick]}
        <Button
          title="Not now"
          kind="plain"
          disabled={busy !== null}
          onPress={onDecline}
          accessibilityHint={`Ignores this request. ${peer} isn’t told`}
        />
      </View>
      <Text variant="footnote" tone="tertiary" center style={styles.expires}>
        Only paired devices can ask · expires in{' '}
        {countdownCoarse(request.expiresAt - now)}
      </Text>
    </Stage>
  );
}

const styles = StyleSheet.create({
  head: {
    alignItems: 'center',
    gap: spacing.xs,
    marginTop: spacing.md,
    paddingHorizontal: spacing.xs,
  },
  art: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 160,
  },
  disc: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  actions: { gap: spacing.sm },
  expires: { marginTop: spacing.sm },
});
