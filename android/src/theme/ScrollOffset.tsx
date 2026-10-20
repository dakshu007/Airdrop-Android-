import { createContext, useContext } from 'react';
import { Animated } from 'react-native';

/**
 * Vertical scroll offset of the nearest scrolling screen. Glass surfaces use it
 * to keep their frosted wallpaper aligned with the real one while scrolling.
 */
export interface ScrollOffset {
  y: Animated.Value;
  /** Latest JS-side value, for measuring. */
  current: { value: number };
}

const still: ScrollOffset = { y: new Animated.Value(0), current: { value: 0 } };

export const ScrollOffsetContext = createContext<ScrollOffset>(still);

export function useScrollOffset() {
  return useContext(ScrollOffsetContext);
}
