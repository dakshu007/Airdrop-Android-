import React, {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  Animated,
  ImageSourcePropType,
  LayoutRectangle,
  StyleSheet,
  useColorScheme,
  View,
} from 'react-native';
import Svg, { Defs, LinearGradient, Rect, Stop } from 'react-native-svg';
import { useReducedMotion } from '../hooks/useReducedMotion';

export type WallpaperName = 'dusk' | 'lagoon' | 'canopy' | 'midnight';
export type WallpaperChoice = WallpaperName | 'auto';

interface WallpaperAsset {
  label: string;
  image: ImageSourcePropType;
  /** Low-resolution, pre-blurred copy shown through glass surfaces. */
  blur: ImageSourcePropType;
  /** Wash over frosted glass; bright wallpapers get a deeper tint so white text stays legible. */
  glass: string;
}

/** Original artwork rendered by scripts/make_wallpapers.py. */
export const WALLPAPERS: Record<WallpaperName, WallpaperAsset> = {
  dusk: {
    label: 'Dusk',
    image: require('../assets/wallpapers/dusk.jpg'),
    blur: require('../assets/wallpapers/dusk-blur.jpg'),
    glass: 'rgba(40,24,80,0.14)',
  },
  lagoon: {
    label: 'Lagoon',
    image: require('../assets/wallpapers/lagoon.jpg'),
    blur: require('../assets/wallpapers/lagoon-blur.jpg'),
    glass: 'rgba(8,46,112,0.2)',
  },
  canopy: {
    label: 'Canopy',
    image: require('../assets/wallpapers/canopy.jpg'),
    blur: require('../assets/wallpapers/canopy-blur.jpg'),
    glass: 'rgba(255,255,255,0.1)',
  },
  midnight: {
    label: 'Midnight',
    image: require('../assets/wallpapers/midnight.jpg'),
    blur: require('../assets/wallpapers/midnight-blur.jpg'),
    glass: 'rgba(255,255,255,0.09)',
  },
};

export const WALLPAPER_NAMES = Object.keys(WALLPAPERS) as WallpaperName[];

export function resolveWallpaper(
  choice: string | undefined,
  scheme: string | null | undefined,
): WallpaperName {
  if (choice && choice in WALLPAPERS) return choice as WallpaperName;
  return scheme === 'light' ? 'lagoon' : 'dusk';
}

interface WallpaperContextValue {
  name: WallpaperName;
  asset: WallpaperAsset;
  /** Where the full-screen wallpaper sits in window coordinates. */
  frame: LayoutRectangle | null;
}

const WallpaperContext = createContext<WallpaperContextValue>({
  name: 'dusk',
  asset: WALLPAPERS.dusk,
  frame: null,
});

export function useWallpaper() {
  return useContext(WallpaperContext);
}

/**
 * Full-screen wallpaper with a soft legibility scrim, cross-fading when the
 * choice changes. Children render above it and can read the wallpaper's
 * frame to align frosted glass.
 */
export function WallpaperBackdrop({
  choice,
  children,
}: {
  choice: string | undefined;
  children: React.ReactNode;
}) {
  const scheme = useColorScheme();
  const reduced = useReducedMotion();
  const name = resolveWallpaper(choice, scheme);
  const [frame, setFrame] = useState<LayoutRectangle | null>(null);
  const [previous, setPrevious] = useState<WallpaperName | null>(null);
  const shown = useRef(name);
  const fade = useRef(new Animated.Value(1)).current;
  const root = useRef<React.ComponentRef<typeof View>>(null);

  useEffect(() => {
    if (shown.current === name) return;
    setPrevious(shown.current);
    shown.current = name;
    fade.setValue(0);
    Animated.timing(fade, {
      toValue: 1,
      duration: reduced ? 0 : 520,
      useNativeDriver: true,
    }).start(() => setPrevious(null));
  }, [name, fade, reduced]);

  const value = useMemo(
    () => ({ name, asset: WALLPAPERS[name], frame }),
    [name, frame],
  );

  return (
    <View
      ref={root}
      style={styles.flex}
      onLayout={() =>
        root.current?.measureInWindow((x, y, width, height) =>
          setFrame({ x, y, width, height }),
        )
      }
    >
      {previous ? (
        <Animated.Image
          source={WALLPAPERS[previous].image}
          style={StyleSheet.absoluteFill}
          resizeMode="cover"
          accessible={false}
        />
      ) : null}
      <Animated.Image
        source={WALLPAPERS[name].image}
        style={[StyleSheet.absoluteFill, { opacity: fade }]}
        resizeMode="cover"
        accessible={false}
      />
      <Scrim />
      <WallpaperContext.Provider value={value}>
        {children}
      </WallpaperContext.Provider>
    </View>
  );
}

/** An opaque copy of the current wallpaper, for full-screen layers that slide over the app. */
export function WallpaperFill() {
  const { asset } = useWallpaper();
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      <Animated.Image source={asset.image} style={StyleSheet.absoluteFill} resizeMode="cover" accessible={false} />
      <Scrim />
    </View>
  );
}

/** Darkens the very top (status bar) and bottom (tab bar) for legibility. */
function Scrim() {
  return (
    <Svg
      style={StyleSheet.absoluteFill}
      width="100%"
      height="100%"
      preserveAspectRatio="none"
      pointerEvents="none"
    >
      <Defs>
        <LinearGradient id="wallScrim" x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor="#05060f" stopOpacity={0.42} />
          <Stop offset="0.22" stopColor="#05060f" stopOpacity={0.12} />
          <Stop offset="0.7" stopColor="#05060f" stopOpacity={0.08} />
          <Stop offset="1" stopColor="#05060f" stopOpacity={0.4} />
        </LinearGradient>
      </Defs>
      <Rect x="0" y="0" width="100%" height="100%" fill="url(#wallScrim)" />
    </Svg>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1, backgroundColor: '#0B0D18' },
});
