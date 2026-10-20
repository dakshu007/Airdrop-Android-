/**
 * Design tokens. Glass surfaces are translucent fills over the aurora
 * backdrop; contrast is chosen so body text stays legible (WCAG AA) on the
 * glass in both appearances.
 */

export const radii = { sm: 12, md: 20, lg: 28, pill: 999 } as const;

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

export const lightPalette: Palette = {
  scheme: 'light',
  background: '#EAEFF8',
  aurora: ['#6F97FF', '#A98BFF', '#4FD6CD', '#FF9EBF'],
  auroraOpacity: 0.55,
  glassFill: 'rgba(255,255,255,0.58)',
  glassFillStrong: 'rgba(255,255,255,0.82)',
  glassBorder: 'rgba(255,255,255,0.9)',
  glassShade: 'rgba(15,23,42,0.08)',
  specular: 'rgba(255,255,255,0.75)',
  textPrimary: '#0B1220',
  textSecondary: '#3E4A5E',
  textTertiary: '#56637A',
  accent: '#2F5FEF',
  onAccent: '#FFFFFF',
  accentSoft: 'rgba(47,95,239,0.13)',
  success: '#157A3C',
  successSoft: 'rgba(21,122,60,0.13)',
  danger: '#C2261F',
  dangerSoft: 'rgba(194,38,31,0.12)',
  warning: '#8F4A00',
  warningSoft: 'rgba(196,110,0,0.14)',
  track: 'rgba(15,23,42,0.10)',
  scrim: 'rgba(8,12,22,0.38)',
  focus: '#2F5FEF',
};

export const darkPalette: Palette = {
  scheme: 'dark',
  background: '#060A13',
  aurora: ['#2D4FFF', '#7A3CEB', '#0FA3A0', '#C2367A'],
  auroraOpacity: 0.42,
  glassFill: 'rgba(255,255,255,0.075)',
  glassFillStrong: 'rgba(28,34,50,0.92)',
  glassBorder: 'rgba(255,255,255,0.16)',
  glassShade: 'rgba(0,0,0,0.35)',
  specular: 'rgba(255,255,255,0.14)',
  textPrimary: '#F2F5FA',
  textSecondary: '#B4BFD0',
  textTertiary: '#94A1B6',
  accent: '#2F5FEF',
  onAccent: '#FFFFFF',
  accentSoft: 'rgba(110,155,255,0.20)',
  success: '#4ADE80',
  successSoft: 'rgba(74,222,128,0.16)',
  danger: '#FF7A72',
  dangerSoft: 'rgba(255,122,114,0.16)',
  warning: '#FBBF5A',
  warningSoft: 'rgba(251,191,90,0.16)',
  track: 'rgba(255,255,255,0.12)',
  scrim: 'rgba(0,0,0,0.55)',
  focus: '#8FB0FF',
};

export const typography = {
  largeTitle: {
    fontSize: 32,
    lineHeight: 39,
    fontWeight: '700' as const,
    letterSpacing: -0.4,
  },
  title: {
    fontSize: 24,
    lineHeight: 30,
    fontWeight: '700' as const,
    letterSpacing: -0.2,
  },
  headline: { fontSize: 17, lineHeight: 23, fontWeight: '600' as const },
  body: { fontSize: 16, lineHeight: 22, fontWeight: '400' as const },
  callout: { fontSize: 15, lineHeight: 21, fontWeight: '400' as const },
  subhead: { fontSize: 14, lineHeight: 19, fontWeight: '500' as const },
  footnote: { fontSize: 13, lineHeight: 18, fontWeight: '400' as const },
  caption: {
    fontSize: 12,
    lineHeight: 16,
    fontWeight: '500' as const,
    letterSpacing: 0.2,
  },
  code: {
    fontSize: 44,
    lineHeight: 52,
    fontWeight: '700' as const,
    letterSpacing: 2,
  },
} as const;

export type TypographyVariant = keyof typeof typography;
