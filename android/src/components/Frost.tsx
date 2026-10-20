import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';

interface FrostProps {
  radius: number;
  /** Fill instead of the standard white glass (e.g. a mint or danger wash). */
  tint?: string;
  /** Hide the bright rim (e.g. for nested surfaces). */
  borderless?: boolean;
}

/** Soft specular sheen across the top of every glass surface. */
const SHEEN =
  'linear-gradient(180deg, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.08) 30%, rgba(255,255,255,0) 60%)';

/**
 * White glass over the mint backdrop: a translucent fill, a soft specular
 * sheen across the top and a bright rim that catches the light. Drawn with
 * native gradients, so it appears in the first frame (no measuring pass) and
 * costs nothing while things animate. Place as the first child of a container
 * with the same border radius; it fills it and ignores touches.
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
          backgroundImage: SHEEN,
        },
      ]}
    />
  );
}

/** Soft green shadow under floating glass (cards, chips, the tab bar). */
export const glassShadow = {
  boxShadow: '0px 10px 24px rgba(24,84,52,0.08)',
} as const;

export const floatShadow = {
  boxShadow: '0px 12px 28px rgba(24,84,52,0.13)',
} as const;
