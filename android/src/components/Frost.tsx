import React from 'react';
import { Image, StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';

interface FrostProps {
  radius: number;
  /** Fill instead of the standard white glass (e.g. a mint or danger wash). */
  tint?: string;
  /** Hide the bright rim (e.g. for nested surfaces). */
  borderless?: boolean;
}

/** Pre-drawn images (scripts/make_ui_textures.py): one texture each, no per-pixel work. */
const SHEEN = require('../assets/ui/sheen.png');
const SHADOW = require('../assets/ui/shadow.png');

/**
 * White glass over the mint backdrop: a translucent fill, a soft specular
 * sheen across the top and a bright rim that catches the light. The sheen is
 * a tiny stretched image, so the surface appears in the first frame (no
 * measuring pass) and costs almost nothing while things animate. Place as the
 * first child of a container with the same border radius; it fills it and
 * ignores touches.
 */
export function Frost({ radius, tint, borderless }: FrostProps) {
  const t = useTheme();
  return (
    <View
      pointerEvents="none"
      style={[
        StyleSheet.absoluteFill,
        {
          borderRadius: radius,
          backgroundColor: tint ?? t.glassFill,
          borderWidth: borderless ? 0 : 1,
          borderColor: t.glassBorder,
          overflow: 'hidden',
        },
      ]}
    >
      <Image
        source={SHEEN}
        style={styles.sheen}
        resizeMode="stretch"
        fadeDuration={0}
      />
    </View>
  );
}

/**
 * A soft drop shadow: a blurred ellipse image tinted and stretched behind the
 * element. No blur pass, so it costs nothing per frame and works on every
 * GPU. Place it as the first child of a container without `overflow: hidden`.
 */
export function SoftShadow({
  color = '#185434',
  opacity = 0.16,
  offsetY = 10,
  spread = 10,
}: {
  color?: string;
  opacity?: number;
  offsetY?: number;
  spread?: number;
}) {
  return (
    <Image
      source={SHADOW}
      resizeMode="stretch"
      fadeDuration={0}
      pointerEvents="none"
      style={{
        position: 'absolute',
        left: -spread,
        right: -spread,
        top: offsetY - spread / 2,
        bottom: -(offsetY + spread),
        tintColor: color,
        opacity,
      }}
    />
  );
}

const styles = StyleSheet.create({
  sheen: {
    position: 'absolute',
    left: 0,
    right: 0,
    top: 0,
    height: '60%',
    width: '100%',
  },
});
