/**
 * Design tokens. Glass surfaces are translucent fills over the aurora
 * backdrop; contrast is chosen so body text stays legible (WCAG AA) on the
 * glass in both appearances.
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
  aurora: [string, string, string, string];
  auroraOpacity: number;
  glassFill: string;
  glassFillStrong: string;
  glassBorder: string;
  glassShade: string;
  specular: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  accent: string;
  onAccent: string;
  accentSoft: string;
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

/**
 * One "glass on wallpaper" palette. Surfaces are frosted copies of the
 * wallpaper with a white tint, so text is always light; the system
 * appearance picks the default wallpaper instead (see Wallpaper.tsx).
 */
export const glassPalette: Palette = {
  scheme: 'dark',
  background: '#0B0D18',
  aurora: ['#2D4FFF', '#7A3CEB', '#0FA3A0', '#C2367A'],
  auroraOpacity: 0,
  glassFill: 'rgba(255,255,255,0.13)',
  glassFillStrong: 'rgba(255,255,255,0.2)',
  glassBorder: 'rgba(255,255,255,0.3)',
  glassShade: 'rgba(0,0,0,0.28)',
  specular: 'rgba(255,255,255,0.2)',
  textPrimary: '#FFFFFF',
  textSecondary: 'rgba(255,255,255,0.8)',
  textTertiary: 'rgba(255,255,255,0.62)',
  accent: '#FFFFFF',
  onAccent: '#121629',
  accentSoft: 'rgba(255,255,255,0.16)',
  success: '#86F0AE',
  successSoft: 'rgba(110,235,160,0.2)',
  danger: '#FFA59C',
  dangerSoft: 'rgba(255,110,100,0.22)',
  warning: '#FFDA8F',
  warningSoft: 'rgba(255,214,130,0.2)',
  track: 'rgba(255,255,255,0.2)',
  scrim: 'rgba(4,5,14,0.5)',
  focus: '#9CC8FF',
};

/** Kept for code that still distinguishes appearances; both use the glass look. */
export const lightPalette = glassPalette;
export const darkPalette = glassPalette;

/** Selected/active pill (like a pressed glass key). */
export const selectedFill = 'rgba(8,10,22,0.5)';
/** Light-blue accent for links and highlights on glass. */
export const accentText = '#A9CDFF';

/** Poppins (bundled, OFL). Android picks the face by family name, so weights are separate families. */
export const fonts = {
  regular: 'Poppins-Regular',
  medium: 'Poppins-Medium',
  semibold: 'Poppins-SemiBold',
  bold: 'Poppins-Bold',
} as const;

export const typography = {
  largeTitle: { fontSize: 30, lineHeight: 40, fontFamily: fonts.semibold, letterSpacing: -0.3 },
  title: { fontSize: 22, lineHeight: 30, fontFamily: fonts.semibold, letterSpacing: -0.2 },
  headline: { fontSize: 16, lineHeight: 23, fontFamily: fonts.semibold },
  body: { fontSize: 15, lineHeight: 22, fontFamily: fonts.regular },
  callout: { fontSize: 14, lineHeight: 21, fontFamily: fonts.regular },
  subhead: { fontSize: 13.5, lineHeight: 19, fontFamily: fonts.medium },
  footnote: { fontSize: 12.5, lineHeight: 18, fontFamily: fonts.regular },
  caption: { fontSize: 11.5, lineHeight: 16, fontFamily: fonts.medium, letterSpacing: 0.2 },
  code: { fontSize: 46, lineHeight: 58, fontFamily: fonts.semibold, letterSpacing: 3 },
} as const;

export type TypographyVariant = keyof typeof typography;
