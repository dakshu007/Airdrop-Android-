/**
 * Mint Air design tokens (design/canvas). A light, airy mint backdrop, white
 * glass surfaces with a bright rim, dark ink type and a black pill for the
 * main action. Text colours meet WCAG AA on the glass and on the backdrop.
 */

export const radii = { sm: 14, md: 22, lg: 28, pill: 999 } as const;

export const spacing = {
  xxs: 4,
  xs: 8,
  sm: 12,
  md: 16,
  lg: 20,
  xl: 24,
  xxl: 32,
  xxxl: 44,
} as const;

/** Minimum touch target (dp). */
export const minTouch = 48;

export interface Palette {
  scheme: 'light' | 'dark';
  background: string;
  glassFill: string;
  glassFillStrong: string;
  glassBorder: string;
  /** Inset rows inside a glass card (file rows, fingerprints). */
  inset: string;
  hairline: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  /** Main action fill (the black pill) and the text on it. */
  accent: string;
  onAccent: string;
  /** Mint tint behind icons and the selected tab. */
  accentSoft: string;
  link: string;
  success: string;
  successSoft: string;
  danger: string;
  dangerSoft: string;
  warning: string;
  warningSoft: string;
  track: string;
  scrim: string;
  focus: string;
}

export const mintPalette: Palette = {
  scheme: 'light',
  background: '#EAF7EE',
  glassFill: 'rgba(255,255,255,0.72)',
  glassFillStrong: 'rgba(255,255,255,0.86)',
  glassBorder: 'rgba(255,255,255,0.95)',
  inset: 'rgba(240,248,242,0.92)',
  hairline: '#E1EEE5',
  textPrimary: '#0F1D16',
  textSecondary: '#4B5B52',
  textTertiary: '#5E6E65',
  accent: '#0F1D16',
  onAccent: '#FFFFFF',
  accentSoft: '#DDF3E3',
  link: '#0B6B3F',
  success: '#0E7D49',
  successSoft: '#DDF3E3',
  danger: '#A8442B',
  dangerSoft: '#FBE9E2',
  warning: '#8A5A00',
  warningSoft: '#FFF1D2',
  track: 'rgba(20,154,91,0.14)',
  scrim: 'rgba(15,29,22,0.32)',
  focus: '#149A5B',
};

/** Brand green for dots, switches and progress. */
export const green = '#149A5B';
export const greenLight = '#6FD493';
/** Soft drop shadow tint for floating glass. */
export const shadowTint = 'rgba(24,84,52,1)';

/** Poppins (bundled, OFL). Android picks the face by family name, so weights are separate families. */
export const fonts = {
  regular: 'Poppins-Regular',
  medium: 'Poppins-Medium',
  semibold: 'Poppins-SemiBold',
  bold: 'Poppins-Bold',
} as const;

export const typography = {
  display: {
    fontSize: 40,
    lineHeight: 46,
    fontFamily: fonts.bold,
    letterSpacing: -1,
  },
  largeTitle: {
    fontSize: 32,
    lineHeight: 38,
    fontFamily: fonts.bold,
    letterSpacing: -0.8,
  },
  title: {
    fontSize: 24,
    lineHeight: 30,
    fontFamily: fonts.bold,
    letterSpacing: -0.5,
  },
  headline: { fontSize: 16, lineHeight: 23, fontFamily: fonts.semibold },
  body: { fontSize: 15, lineHeight: 22, fontFamily: fonts.regular },
  callout: { fontSize: 14, lineHeight: 21, fontFamily: fonts.regular },
  subhead: { fontSize: 13.5, lineHeight: 19, fontFamily: fonts.medium },
  footnote: { fontSize: 12.5, lineHeight: 18, fontFamily: fonts.regular },
  caption: {
    fontSize: 11.5,
    lineHeight: 16,
    fontFamily: fonts.medium,
    letterSpacing: 0.2,
  },
  code: { fontSize: 30, lineHeight: 38, fontFamily: fonts.bold },
} as const;

export type TypographyVariant = keyof typeof typography;
