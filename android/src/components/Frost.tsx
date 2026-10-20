import React, { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import Svg, { Defs, LinearGradient, Rect, Stop } from 'react-native-svg';
import { useScrollOffset } from '../theme/ScrollOffset';
import { useWallpaper } from '../theme/Wallpaper';

interface FrostProps {
  radius: number;
  /** Extra wash on top of the wallpaper's own glass tint (e.g. for emphasis). */
  tint?: string;
  /** Hide the hairline border (e.g. for nested surfaces). */
  borderless?: boolean;
}

/**
 * Frosted glass: a pre-blurred copy of the wallpaper aligned to the real one
 * (so it reads as a live backdrop blur), a light wash, a specular sheen on the
 * top edge and a hairline border that is brighter at the top, like light
 * catching the rim of a glass pane. Place as the first child of a container
 * with the same border radius; it fills it and ignores touches.
 */
export function Frost({ radius, tint, borderless }: FrostProps) {
  const { asset, frame } = useWallpaper();
  const scroll = useScrollOffset();
  const ref = useRef<React.ComponentRef<typeof View>>(null);
  const [origin, setOrigin] = useState<{ x: number; y: number } | null>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const gid = `frost${useId().replace(/[^a-zA-Z0-9]/g, '')}`;

  const measure = useCallback(() => {
    if (!frame) return;
    ref.current?.measureInWindow((x, y) => {
      const next = { x: x - frame.x, y: y - frame.y + scroll.current.value };
      setOrigin(o =>
        o && Math.abs(o.x - next.x) < 0.5 && Math.abs(o.y - next.y) < 0.5 ? o : next,
      );
    });
  }, [frame, scroll]);

  // Re-measure after entrance animations settle (sheets slide, cards fade in).
  useEffect(() => {
    const a = setTimeout(measure, 40);
    const b = setTimeout(measure, 480);
    return () => {
      clearTimeout(a);
      clearTimeout(b);
    };
  }, [measure]);

  return (
    <View
      ref={ref}
      pointerEvents="none"
      style={[StyleSheet.absoluteFill, { borderRadius: radius, overflow: 'hidden' }]}
      onLayout={e => {
        const { width, height } = e.nativeEvent.layout;
        setSize(s => (s && s.w === width && s.h === height ? s : { w: width, h: height }));
        measure();
      }}
    >
      {frame && origin ? (
        <Animated.Image
          source={asset.blur}
          resizeMode="cover"
          accessible={false}
          style={{
            position: 'absolute',
            left: -origin.x,
            top: -origin.y,
            width: frame.width,
            height: frame.height,
            transform: [{ translateY: scroll.y }],
          }}
        />
      ) : null}
      <View style={[StyleSheet.absoluteFill, { backgroundColor: asset.glass }]} />
      {tint ? <View style={[StyleSheet.absoluteFill, { backgroundColor: tint }]} /> : null}
      {size ? (
        <Svg width={size.w} height={size.h} style={StyleSheet.absoluteFill}>
          <Defs>
            <LinearGradient id={`${gid}s`} x1="0" y1="0" x2="0" y2="1">
              <Stop offset="0" stopColor="#ffffff" stopOpacity={0.2} />
              <Stop offset="0.45" stopColor="#ffffff" stopOpacity={0.03} />
              <Stop offset="1" stopColor="#ffffff" stopOpacity={0} />
            </LinearGradient>
            <LinearGradient id={`${gid}b`} x1="0" y1="0" x2="0.35" y2="1">
              <Stop offset="0" stopColor="#ffffff" stopOpacity={0.62} />
              <Stop offset="0.5" stopColor="#ffffff" stopOpacity={0.18} />
              <Stop offset="1" stopColor="#ffffff" stopOpacity={0.3} />
            </LinearGradient>
          </Defs>
          <Rect x={0} y={0} width={size.w} height={size.h} rx={radius} fill={`url(#${gid}s)`} />
          {borderless ? null : (
            <Rect
              x={0.5}
              y={0.5}
              width={Math.max(size.w - 1, 0)}
              height={Math.max(size.h - 1, 0)}
              rx={Math.max(radius - 0.5, 0)}
              fill="none"
              stroke={`url(#${gid}b)`}
              strokeWidth={1}
            />
          )}
        </Svg>
      ) : null}
    </View>
  );
}
