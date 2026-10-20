import React, { useId, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import Svg, { Defs, LinearGradient, Rect, Stop } from 'react-native-svg';
import { useTheme } from '../theme/ThemeProvider';

interface FrostProps {
  radius: number;
  /** Fill instead of the standard white glass (e.g. a mint or danger wash). */
  tint?: string;
  /** Hide the bright rim (e.g. for nested surfaces). */
  borderless?: boolean;
}

/**
 * White glass over the mint backdrop: a translucent fill, a soft specular
 * sheen across the top and a bright rim that catches the light. Place as the
 * first child of a container with the same border radius; it fills it and
 * ignores touches.
 */
export function Frost({ radius, tint, borderless }: FrostProps) {
  const t = useTheme();
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const gid = `frost${useId().replace(/[^a-zA-Z0-9]/g, '')}`;
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
      onLayout={e => {
        const { width, height } = e.nativeEvent.layout;
        setSize(s =>
          s && s.w === width && s.h === height ? s : { w: width, h: height },
        );
      }}
    >
      {size ? (
        <Svg width={size.w} height={size.h} style={StyleSheet.absoluteFill}>
          <Defs>
            <LinearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
              <Stop offset="0" stopColor="#ffffff" stopOpacity={0.55} />
              <Stop offset="0.5" stopColor="#ffffff" stopOpacity={0.08} />
              <Stop offset="1" stopColor="#ffffff" stopOpacity={0} />
            </LinearGradient>
          </Defs>
          <Rect
            x={0}
            y={0}
            width={size.w}
            height={size.h * 0.6}
            fill={`url(#${gid})`}
          />
        </Svg>
      ) : null}
    </View>
  );
}
