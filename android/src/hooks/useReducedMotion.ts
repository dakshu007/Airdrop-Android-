import { useEffect, useState } from 'react';
import { AccessibilityInfo } from 'react-native';

/** Last value the system reported, shared so new screens start with the right one. */
let known: boolean | null = null;
const listeners = new Set<(value: boolean) => void>();

function publish(value: boolean) {
  known = value;
  listeners.forEach(l => l(value));
}

let subscribed = false;
function ensureSubscribed() {
  if (subscribed) return;
  subscribed = true;
  AccessibilityInfo.isReduceMotionEnabled()
    .then(publish)
    .catch(() => publish(false));
  AccessibilityInfo.addEventListener('reduceMotionChanged', publish);
}

/**
 * True when the system asks for reduced motion. Until the first answer
 * arrives it is `true`, so nothing moves before the setting is known; after
 * that every component starts with the known value.
 */
export function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(known ?? true);
  useEffect(() => {
    ensureSubscribed();
    listeners.add(setReduced);
    if (known !== null) setReduced(known);
    return () => {
      listeners.delete(setReduced);
    };
  }, []);
  return reduced;
}
