import React, { useEffect, useRef, useState } from 'react';
import { Animated, Easing, Pressable, StyleSheet, View } from 'react-native';
import { useStill } from '../hooks/useStill';
import type { NearbyDevice } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';
import { DeviceChip } from './Chips';
import { Drip, Motion, Pose } from './Drip';
import { Frost } from './Frost';
import { Icon } from './Icon';
import { Text } from './Text';

/** Where chips float around Drip, as fractions of the stage, and which way Drip leans. */
const SLOTS: { side: 'left' | 'right'; top: number; tilt: number }[] = [
  { side: 'left', top: 0.02, tilt: -6 },
  { side: 'right', top: 0.72, tilt: 7 },
  { side: 'right', top: 0.24, tilt: 5 },
  { side: 'left', top: 0.5, tilt: -5 },
];

interface DripStageProps {
  pose: Pose;
  motion: Motion;
  /** Accessible description of the picture, when the screen text doesn't already say it. */
  label?: string;
  /** 'halo' draws soft rings (devices around), 'ping' pulses outward (still looking). */
  rings?: 'halo' | 'ping' | 'none';
  devices?: NearbyDevice[];
  busy?: boolean;
  onSelect?: (device: NearbyDevice) => void;
  actionHint?: (device: NearbyDevice) => string;
  /** Shown as a "+N more" chip when there are more devices than places around Drip. */
  onShowAll?: () => void;
}

function Ping() {
  const reduced = useStill();
  const v = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (reduced) {
      v.setValue(0.6);
      return;
    }
    const anim = Animated.loop(
      Animated.timing(v, {
        toValue: 1,
        duration: 2600,
        easing: Easing.out(Easing.quad),
        useNativeDriver: true,
      }),
    );
    anim.start();
    return () => anim.stop();
  }, [reduced, v]);
  return (
    <Animated.View
      style={[
        styles.ring,
        styles.pingRing,
        {
          opacity: reduced
            ? 0.25
            : v.interpolate({ inputRange: [0, 1], outputRange: [0.6, 0] }),
          transform: [
            {
              scale: v.interpolate({
                inputRange: [0, 1],
                outputRange: [0.4, 1.25],
              }),
            },
          ],
        },
      ]}
    />
  );
}

/** Drip in the middle of the screen, with nearby devices floating around as tappable chips. */
export function DripStage({
  pose,
  motion,
  label,
  rings = 'none',
  devices = [],
  busy,
  onSelect,
  actionHint,
  onShowAll,
}: DripStageProps) {
  const t = useTheme();
  const [box, setBox] = useState<{ w: number; h: number } | null>(null);
  const [lean, setLean] = useState(0);
  const size = box ? Math.round(Math.min(box.w * 0.84, box.h * 0.96, 340)) : 0;

  const overflow = devices.length > SLOTS.length;
  const shown = overflow ? devices.slice(0, SLOTS.length - 1) : devices;

  return (
    <View
      style={styles.stage}
      onLayout={e =>
        setBox({
          w: e.nativeEvent.layout.width,
          h: e.nativeEvent.layout.height,
        })
      }
    >
      {box ? (
        <>
          <View
            style={[StyleSheet.absoluteFill, styles.center]}
            pointerEvents="none"
          >
            {rings === 'halo' ? (
              <>
                <View
                  style={[
                    styles.ring,
                    styles.haloOuter,
                    { width: size * 1.02, height: size * 1.02 },
                  ]}
                />
                <View
                  style={[
                    styles.ring,
                    styles.haloInner,
                    { width: size * 0.68, height: size * 0.68 },
                  ]}
                />
              </>
            ) : null}
            {rings === 'ping' ? (
              <View style={{ width: size * 0.94, height: size * 0.94 }}>
                <Ping />
              </View>
            ) : null}
          </View>
          <View
            style={[StyleSheet.absoluteFill, styles.center]}
            pointerEvents="none"
          >
            <Drip
              pose={pose}
              size={size}
              motion={motion}
              lean={lean}
              label={label}
            />
          </View>
          {shown.map((device, i) => {
            const slot = SLOTS[i];
            return (
              <DeviceChip
                key={device.deviceId}
                device={device}
                tilt={slot.tilt}
                phase={i}
                disabled={busy}
                actionHint={
                  actionHint ? actionHint(device) : `Send to ${device.name}`
                }
                onPress={() => onSelect?.(device)}
                onFocusChange={focused =>
                  setLean(focused ? (slot.side === 'left' ? -1 : 1) : 0)
                }
                style={[
                  styles.chip,
                  slot.side === 'left' ? styles.left : styles.right,
                  { top: box.h * slot.top, maxWidth: box.w * 0.6 },
                ]}
              />
            );
          })}
          {overflow ? (
            <Pressable
              onPress={onShowAll}
              accessibilityRole="button"
              accessibilityLabel={`${
                devices.length - shown.length
              } more devices`}
              accessibilityHint="Shows every nearby device"
              style={[
                styles.chip,
                styles.more,
                styles.left,
                { top: box.h * SLOTS[3].top },
              ]}
            >
              <Frost radius={18} />
              <Icon name="devices" size={18} color={t.link} />
              <Text variant="headline" style={styles.moreText}>
                +{devices.length - shown.length} more
              </Text>
            </Pressable>
          ) : null}
        </>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  stage: { flex: 1, minHeight: 220, marginHorizontal: -spacing.sm },
  center: { alignItems: 'center', justifyContent: 'center' },
  ring: { position: 'absolute', borderRadius: 999 },
  haloOuter: { borderWidth: 1, borderColor: 'rgba(46,158,102,0.16)' },
  haloInner: {
    borderWidth: 1,
    borderColor: 'rgba(46,158,102,0.22)',
    backgroundColor: 'rgba(190,245,170,0.28)',
  },
  pingRing: {
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    borderWidth: 2,
    borderColor: 'rgba(20,154,91,0.35)',
  },
  chip: { position: 'absolute' },
  left: { left: 2 },
  right: { right: 2 },
  more: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    minHeight: 52,
    paddingHorizontal: 16,
    borderRadius: 18,
    overflow: 'hidden',
    transform: [{ rotate: '-5deg' }],
  },
  moreText: { fontSize: 14 },
});
