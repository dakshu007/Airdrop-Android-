import { useEffect, useState } from 'react';
import { AppState } from 'react-native';

const isForeground = (state: string | null | undefined) =>
  state !== 'background' && state !== 'inactive';

/** True while the app is in the foreground. */
export function useAppActive(): boolean {
  const [active, setActive] = useState(isForeground(AppState.currentState));
  useEffect(() => {
    const sub = AppState.addEventListener('change', state =>
      setActive(isForeground(state)),
    );
    return () => sub.remove();
  }, []);
  return active;
}
