import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Easing,
  Image,
  PixelRatio,
  Pressable,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { errorCode, isRoomCode, pairError, roomError } from '../copy';
import { formatClock, formatDuration, formatMinutes } from '../format';
import { useNow } from '../hooks/useNow';
import { useStill } from '../hooks/useStill';
import * as CrossDrop from '../native/crossdrop';
import type { RoomInfo, Snapshot } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { green, minTouch, radii, spacing, typography } from '../theme/tokens';
import { Button } from './Button';
import { Icon } from './Icon';
import { IconBubble } from './IconBubble';
import { roomMembersText } from './RoomBanner';
import { Sheet } from './Sheet';
import { Text } from './Text';

const QR_SIZE = 216;
const MAX_ROOM_NAME = 40;

/** What everyone in a room gets, said the same way everywhere. */
export const ROOM_TRUST_NOTE =
  'Everyone who scans the code can swap files with each other without comparing codes, until the room ends. You still accept each transfer, and the trust ends with the room.';

/**
 * Scans a code and joins the room, or pairs when it's a device's pairing
 * code. Alerts with the result; resolves true when something was joined or
 * paired.
 */
export async function scanAndJoin(mine = false): Promise<boolean> {
  const code = await CrossDrop.scanPairingCode().catch(() => '');
  if (!code) return false;
  return joinWithCode(code, mine);
}

export async function joinWithCode(
  code: string,
  mine: boolean,
): Promise<boolean> {
  if (!isRoomCode(code)) {
    try {
      const name = await CrossDrop.pairWithCode(code, mine);
      CrossDrop.feedback('done');
      Alert.alert(
        `Paired with ${name}`,
        mine
          ? 'Files from it now arrive without asking.'
          : 'You can now send files to each other.',
      );
      return true;
    } catch (e) {
      CrossDrop.feedback('error');
      Alert.alert('Couldn’t pair', pairError(errorCode(e)));
      return false;
    }
  }
  try {
    const { name, hostName } = await CrossDrop.joinRoom(code);
    CrossDrop.feedback('done');
    Alert.alert(
      `You’re in ${name}`,
      hostName
        ? `${hostName} and everyone else in the room can now swap files with this phone until it ends.`
        : 'The phone that showed the code didn’t answer yet. Others in the room appear in Nearby as they’re found.',
    );
    return true;
  } catch (e) {
    CrossDrop.feedback('error');
    Alert.alert('Couldn’t join the room', roomError(errorCode(e)));
    return false;
  }
}

/** Name the room and choose how long it lasts, then host it. */
export function StartRoomSheet({
  snapshot,
  onStarted,
  onClose,
}: {
  snapshot: Snapshot;
  onStarted: () => void;
  onClose: () => void;
}) {
  const t = useTheme();
  const durations =
    snapshot.roomDurations.length > 0 ? snapshot.roomDurations : [60];
  const [name, setName] = useState('');
  const [minutes, setMinutes] = useState(
    durations.includes(60) ? 60 : durations[0],
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fallback = `${snapshot.local.name}’s room`;

  const start = async () => {
    setBusy(true);
    setError(null);
    try {
      await CrossDrop.startRoom(name.trim() || fallback, minutes);
      CrossDrop.feedback('confirm');
      onStarted();
    } catch (e) {
      setError(roomError(errorCode(e)));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet
      visible
      onRequestClose={onClose}
      accessibilityLabel="Start a Drip Room"
    >
      <View style={styles.head}>
        <IconBubble name="users" size={52} />
        <View style={styles.flex}>
          <Text variant="title" accessibilityRole="header">
            Start a Drip Room
          </Text>
          <Text variant="footnote" tone="secondary">
            For a meeting, a class or a trip
          </Text>
        </View>
      </View>
      <Text variant="callout" tone="secondary">
        {ROOM_TRUST_NOTE}
      </Text>

      <View style={styles.field}>
        <Text variant="subhead" tone="secondary" nativeID="roomNameLabel">
          Room name
        </Text>
        <TextInput
          value={name}
          onChangeText={setName}
          maxLength={MAX_ROOM_NAME}
          placeholder={fallback}
          placeholderTextColor={t.textTertiary}
          accessibilityLabel="Room name"
          aria-labelledby="roomNameLabel"
          returnKeyType="done"
          autoCorrect={false}
          style={[styles.input, typography.body, { color: t.textPrimary }]}
        />
        <Text variant="footnote" tone="tertiary">
          Shown to people who scan the code. Avoid personal details.
        </Text>
      </View>

      <View style={styles.field}>
        <Text variant="subhead" tone="secondary">
          Ends after
        </Text>
        <View style={styles.durations} accessibilityRole="radiogroup">
          {durations.map(d => {
            const on = d === minutes;
            return (
              <Pressable
                key={d}
                onPress={() => setMinutes(d)}
                accessibilityRole="radio"
                accessibilityState={{ checked: on }}
                accessibilityLabel={`Ends after ${formatMinutes(d)}`}
                style={[
                  styles.duration,
                  on
                    ? { backgroundColor: t.accent, borderColor: t.accent }
                    : { backgroundColor: t.inset, borderColor: t.hairline },
                ]}
              >
                <Text
                  variant="subhead"
                  tone={on ? 'onAccent' : 'primary'}
                  center
                >
                  {formatMinutes(d)}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </View>

      <View style={[styles.note, { backgroundColor: t.inset }]}>
        <Icon name="wifi" size={18} color={t.link} />
        <Text variant="footnote" tone="secondary" style={styles.flex}>
          Works on this Wi‑Fi only. If Receiving is off, it turns on privately
          for the room and goes back off when the room ends.
        </Text>
      </View>

      {error ? (
        <Text variant="footnote" tone="danger" accessibilityLiveRegion="polite">
          {error}
        </Text>
      ) : null}
      <Button
        title="Start room"
        icon="users"
        large
        loading={busy}
        onPress={start}
      />
      <Button title="Cancel" kind="plain" disabled={busy} onPress={onClose} />
    </Sheet>
  );
}

/** A soft breathing glow behind the QR card; still with Reduce Motion. */
function Glow({ size }: { size: number }) {
  const still = useStill();
  const v = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (still) {
      v.setValue(0.5);
      return;
    }
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(v, {
          toValue: 1,
          duration: 1800,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
        Animated.timing(v, {
          toValue: 0,
          duration: 1800,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
      ]),
    );
    anim.start();
    return () => anim.stop();
  }, [still, v]);
  return (
    <Animated.View
      pointerEvents="none"
      style={[
        styles.glow,
        {
          width: size,
          height: size,
          borderRadius: size * 0.2,
          opacity: v.interpolate({
            inputRange: [0, 1],
            outputRange: [0.35, 0.75],
          }),
          transform: [
            {
              scale: v.interpolate({
                inputRange: [0, 1],
                outputRange: [1, 1.06],
              }),
            },
          ],
        },
      ]}
    />
  );
}

function RoomCode() {
  const t = useTheme();
  const [uri, setUri] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const load = useCallback(() => {
    setFailed(false);
    CrossDrop.roomQrDataUri(PixelRatio.getPixelSizeForLayoutSize(QR_SIZE))
      .then(setUri)
      .catch(() => setFailed(true));
  }, []);
  useEffect(load, [load]);

  return (
    <View style={styles.codeWrap}>
      <Glow size={QR_SIZE + 36} />
      <View
        style={styles.codeCard}
        accessible
        accessibilityRole="image"
        accessibilityLabel="Room code. Others scan it with CrossDrop to join"
      >
        {uri ? (
          <Image
            source={{ uri }}
            style={styles.qr}
            resizeMode="contain"
            fadeDuration={0}
          />
        ) : failed ? (
          <View style={[styles.qr, styles.center]}>
            <Text variant="footnote" tone="secondary" center>
              Couldn’t draw the code.
            </Text>
            <Button title="Try again" kind="plain" compact onPress={load} />
          </View>
        ) : (
          <View style={[styles.qr, styles.center]}>
            <ActivityIndicator color={t.link} />
          </View>
        )}
      </View>
    </View>
  );
}

/** The current room: the code to scan (when hosting), who's in, time left, and End / Leave. */
export function RoomSheet({
  room,
  onClose,
}: {
  room: RoomInfo;
  onClose: () => void;
}) {
  const t = useTheme();
  const now = useNow(15000);
  const end = () =>
    Alert.alert(
      room.hosting ? `End ${room.name}?` : `Leave ${room.name}?`,
      room.hosting
        ? 'The code stops working and trust from the room ends for everyone who joined through this phone.'
        : 'Devices you met in the room can no longer send to you without a code.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: room.hosting ? 'End room' : 'Leave',
          style: 'destructive',
          onPress: () => {
            CrossDrop.leaveRoom();
            onClose();
          },
        },
      ],
    );

  return (
    <Sheet
      visible
      onRequestClose={onClose}
      accessibilityLabel={`Drip Room ${room.name}`}
    >
      <View style={styles.titles}>
        <Text variant="title" center accessibilityRole="header">
          {room.name}
        </Text>
        <Text variant="callout" tone="secondary" center>
          Ends in {formatDuration(room.expiresAt - now)} · at{' '}
          {formatClock(room.expiresAt)}
        </Text>
      </View>

      {room.hosting ? <RoomCode /> : null}

      <View
        style={[styles.members, { backgroundColor: t.inset }]}
        accessible
        accessibilityLabel={roomMembersText(room.members)}
        accessibilityLiveRegion="polite"
      >
        <View style={[styles.memberDot, { backgroundColor: green }]}>
          <Icon name="users" size={16} color="#FFFFFF" strokeWidth={2} />
        </View>
        <Text variant="headline" style={styles.flex}>
          {roomMembersText(room.members)}
        </Text>
      </View>

      <Text variant="footnote" tone="secondary" center>
        {room.hosting
          ? 'Others open CrossDrop, scan this code, and show up in Nearby with a room mark.'
          : 'Room members show up in Nearby with a room mark.'}{' '}
        {ROOM_TRUST_NOTE}
      </Text>

      <Button
        title={room.hosting ? 'End room' : 'Leave room'}
        kind="destructive"
        icon="x"
        onPress={end}
      />
      <Button title="Done" kind="plain" onPress={onClose} />
    </Sheet>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  head: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  titles: { gap: 2 },
  field: { gap: spacing.xxs },
  input: {
    minHeight: minTouch,
    borderWidth: 1.5,
    borderColor: '#D5E7DB',
    borderRadius: radii.sm,
    backgroundColor: '#FFFFFF',
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
  },
  durations: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xs },
  duration: {
    minWidth: 72,
    minHeight: minTouch,
    paddingHorizontal: spacing.md,
    borderRadius: radii.pill,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  note: {
    flexDirection: 'row',
    gap: spacing.sm,
    alignItems: 'flex-start',
    borderRadius: 18,
    padding: spacing.sm,
  },
  codeWrap: {
    alignItems: 'center',
    justifyContent: 'center',
    height: QR_SIZE + 56,
  },
  glow: { position: 'absolute', backgroundColor: 'rgba(111,212,147,0.45)' },
  codeCard: {
    padding: 14,
    borderRadius: 28,
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#E1EEE5',
  },
  qr: { width: QR_SIZE, height: QR_SIZE },
  center: { alignItems: 'center', justifyContent: 'center', gap: spacing.xs },
  members: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    borderRadius: 18,
    padding: spacing.sm,
    minHeight: minTouch + 8,
  },
  memberDot: {
    width: 30,
    height: 30,
    borderRadius: 15,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
