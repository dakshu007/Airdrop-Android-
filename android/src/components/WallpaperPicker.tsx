import React from 'react';
import { Image, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import * as CrossDrop from '../native/crossdrop';
import { WALLPAPER_NAMES, WALLPAPERS } from '../theme/Wallpaper';
import { spacing } from '../theme/tokens';
import { Icon } from './Icon';
import { Text } from './Text';

const W = 66;
const H = 116;
const R = 16;

/** Wallpaper thumbnails. "Auto" follows the system appearance (Lagoon in light, Dusk in dark). */
export function WallpaperPicker({ value }: { value: string }) {
  const options = ['auto', ...WALLPAPER_NAMES];
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.row}>
      {options.map(option => {
        const selected = (value || 'auto') === option;
        const label = option === 'auto' ? 'Auto' : WALLPAPERS[option as keyof typeof WALLPAPERS].label;
        return (
          <Pressable
            key={option}
            onPress={() => CrossDrop.setWallpaper(option)}
            accessibilityRole="radio"
            accessibilityLabel={option === 'auto' ? 'Automatic wallpaper, follows light and dark mode' : `${label} wallpaper`}
            accessibilityState={{ selected }}
            style={styles.option}
          >
            <View style={[styles.thumb, selected && styles.thumbSelected]}>
              {option === 'auto' ? (
                <View style={styles.split}>
                  <Image source={WALLPAPERS.lagoon.image} style={styles.half} resizeMode="cover" />
                  <Image source={WALLPAPERS.dusk.image} style={styles.half} resizeMode="cover" />
                </View>
              ) : (
                <Image source={WALLPAPERS[option as keyof typeof WALLPAPERS].image} style={styles.image} resizeMode="cover" />
              )}
              {selected ? (
                <View style={styles.check}>
                  <Icon name="check" size={13} color="#121629" strokeWidth={2.6} />
                </View>
              ) : null}
            </View>
            <Text variant="caption" tone={selected ? 'primary' : 'secondary'} center>
              {label}
            </Text>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  row: { gap: spacing.sm, paddingVertical: spacing.xxs, paddingRight: spacing.xs },
  option: { alignItems: 'center', gap: 6 },
  thumb: {
    width: W,
    height: H,
    borderRadius: R,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.35)',
  },
  thumbSelected: { borderWidth: 2.5, borderColor: '#FFFFFF' },
  image: { width: '100%', height: '100%' },
  split: { flex: 1, flexDirection: 'row' },
  half: { flex: 1, height: '100%' },
  check: {
    position: 'absolute',
    right: 6,
    bottom: 6,
    width: 22,
    height: 22,
    borderRadius: 11,
    backgroundColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
