import React, { useEffect, useRef, useState } from 'react';
import { Animated, Pressable, StyleSheet, View } from 'react-native';
import { formatDuration } from '../format';
import { useNow } from '../hooks/useNow';
import { useReducedMotion } from '../hooks/useReducedMotion';
import * as CrossDrop from '../native/crossdrop';
import type { Clip } from '../native/types';
import { useTheme } from '../theme/ThemeProvider';
import { green, minTouch, spacing } from '../theme/tokens';
import { Button } from './Button';
import { Frost, SoftShadow } from './Frost';
import { Icon } from './Icon';
import { Ripple } from './Ripple';
import { Text } from './Text';

/** How long the engine offers a clip (Engine.CLIP_TTL_MS). */
const CLIP_TTL_MS = 120_000;
const COPIED_LINGER_MS = 1400;

/**
 * "Paste from <Mac>": text that just arrived from a paired Mac, offered for
 * two minutes as a floating glass pill. It floats over the header, so the
 * screen underneath never moves. A hairline drains as the time runs out;
 * with Reduce Motion it shows the time left in words instead.
 */
export function ClipPill({ clip }: { clip: Clip }) {
  const t = useTheme();
  const reduced = useReducedMotion();
  const [copied, setCopied] = useState(false);
  const [gone, setGone] = useState(false);
  const now = useNow(15000, reduced && !gone);
  const enter = useRef(new Animated.Value(0)).current;
  const drain = useRef(
    new Animated.Value(
      Math.max(0, Math.min(1, (clip.expiresAt - Date.now()) / CLIP_TTL_MS)),
    ),
  ).current;

  useEffect(() => {
    const anim = reduced
      ? Animated.timing(enter, {
          toValue: 1,
          duration: 160,
          useNativeDriver: true,
        })
      : Animated.spring(enter, {
          toValue: 1,
          useNativeDriver: true,
          speed: 13,
          bounciness: 9,
        });
    anim.start();
    return () => anim.stop();
  }, [reduced, enter]);

  // One timer for the end and, with motion, one native animation for the bar: no polling.
  useEffect(() => {
    const left = Math.max(0, clip.expiresAt - Date.now());
    const timer = setTimeout(() => setGone(true), left);
    let anim: Animated.CompositeAnimation | null = null;
    if (!reduced) {
      anim = Animated.timing(drain, {
        toValue: 0,
        duration: left,
        useNativeDriver: true,
      });
      anim.start();
    }
    return () => {
      clearTimeout(timer);
      anim?.stop();
    };
  }, [clip.expiresAt, reduced, drain]);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => CrossDrop.dismissClip(), COPIED_LINGER_MS);
    return () => clearTimeout(timer);
  }, [copied]);

  if (gone) return null;

  const copy = async () => {
    const ok = await CrossDrop.copyClip().catch(() => false);
    if (ok) {
      setCopied(true);
      CrossDrop.feedback('tick');
    } else {
      setGone(true);
      CrossDrop.dismissClip();
    }
  };

  const left = clip.expiresAt - now;

  return (
    <Animated.View
      style={[
        styles.wrap,
        {
          opacity: enter,
          transform: [
            {
              translateY: enter.interpolate({
                inputRange: [0, 1],
                outputRange: [reduced ? 0 : -24, 0],
              }),
            },
            {
              scale: enter.interpolate({
                inputRange: [0, 1],
                outputRange: [reduced ? 1 : 0.92, 1],
              }),
            },
          ],
        },
      ]}
      accessibilityLiveRegion="polite"
    >
      <SoftShadow offsetY={10} spread={10} opacity={0.2} />
      <View style={styles.pill}>
        <Frost radius={28} tint="rgba(255,255,255,0.9)" />
        <Ripple size={52} rings={2} duration={2200}>
          <View style={[styles.icon, { backgroundColor: t.accentSoft }]}>
            <Icon
              name={copied ? 'check' : 'clipboard'}
              size={20}
              color={copied ? green : t.link}
              strokeWidth={2}
            />
          </View>
        </Ripple>
        <View style={styles.text}>
          <Text variant="headline" numberOfLines={1} style={styles.title}>
            {copied ? 'Copied' : `Paste from ${clip.from}`}
          </Text>
          <Text variant="footnote" tone="secondary" numberOfLines={1}>
            {copied
              ? 'Ready to paste anywhere'
              : reduced
              ? `${clip.preview} · ${formatDuration(left)} left`
              : clip.preview}
          </Text>
        </View>
        {copied ? null : (
          <Button
            title="Copy"
            compact
            onPress={copy}
            accessibilityLabel={`Copy text from ${clip.from}`}
          />
        )}
        <Pressable
          onPress={() => {
            setGone(true);
            CrossDrop.dismissClip();
          }}
          accessibilityRole="button"
          accessibilityLabel="Dismiss"
          hitSlop={4}
          style={styles.close}
        >
          <Icon name="x" size={18} color={t.textSecondary} />
        </Pressable>
        {reduced ? null : (
          <Animated.View
            pointerEvents="none"
            style={[
              styles.drain,
              { backgroundColor: green, transform: [{ scaleX: drain }] },
            ]}
          />
        )}
      </View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  wrap: { borderRadius: 28 },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    minHeight: 64,
    paddingLeft: spacing.xxs,
    paddingRight: spacing.xxs,
    borderRadius: 28,
    overflow: 'hidden',
  },
  icon: {
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1, minWidth: 0 },
  title: { fontSize: 15 },
  close: {
    width: minTouch,
    height: minTouch,
    alignItems: 'center',
    justifyContent: 'center',
  },
  drain: {
    position: 'absolute',
    left: 24,
    right: 24,
    bottom: 0,
    height: 2,
    borderRadius: 1,
    opacity: 0.6,
  },
});
