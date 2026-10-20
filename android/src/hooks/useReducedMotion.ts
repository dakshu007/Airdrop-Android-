import { useEffect, useState } from 'react';
import { AccessibilityInfo } from 'react-native';

/**
 * True when the system asks for reduced motion. Starts as `true` so nothing
 * moves before the real setting is known.
 */
export function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(true);
  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled()
      .then(value => mounted && setReduced(value))
      .catch(() => mounted && setReduced(false));
    const sub = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      value => setReduced(value),
    );
    return () => {
      mounted = false;
      sub.remove();
    };
  }, []);
  return reduced;
}
