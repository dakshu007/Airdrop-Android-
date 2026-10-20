import { useEffect } from 'react';
import * as CrossDrop from '../native/crossdrop';

/**
 * Keeps discovery running only while `active` (a discovery screen is focused
 * and the app is in the foreground). Stops promptly otherwise to save battery.
 */
export function useDiscovery(active: boolean): void {
  useEffect(() => {
    if (!active) {
      return;
    }
    CrossDrop.startDiscovery();
    return () => CrossDrop.stopDiscovery();
  }, [active]);
}
