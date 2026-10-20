import { createContext, useContext } from 'react';
import { useReducedMotion } from './useReducedMotion';

/** False while a tab is hidden behind another one (it stays mounted). */
export const ScreenVisibleContext = createContext(true);

/**
 * True when looping decoration should hold still: Reduce Motion is on, or the
 * screen it lives on is hidden, so no frames are spent on what no one sees.
 */
export function useStill(): boolean {
  const reduced = useReducedMotion();
  const visible = useContext(ScreenVisibleContext);
  return reduced || !visible;
}
