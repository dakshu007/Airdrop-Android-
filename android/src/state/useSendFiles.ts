import { useCallback, useState } from 'react';
import { Alert } from 'react-native';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice, SharedFile } from '../native/types';

/**
 * Starts a transfer; the transfer stage (overlays/Overlays.tsx) picks it up.
 * Returns `busy` while the native side is accepting the request.
 */
export function useSendFiles() {
  const [busy, setBusy] = useState(false);

  const send = useCallback(
    async (device: NearbyDevice, files: SharedFile[]): Promise<boolean> => {
      if (files.length === 0) {
        return false;
      }
      setBusy(true);
      try {
        await CrossDrop.sendFiles(device.deviceId, files);
        return true;
      } catch (e) {
        Alert.alert(
          `Couldn’t send to ${device.name}`,
          e instanceof Error && e.message
            ? e.message
            : 'Something went wrong. Try again.',
        );
        return false;
      } finally {
        setBusy(false);
      }
    },
    [],
  );

  return { send, busy };
}

export async function pickFilesSafely(): Promise<SharedFile[]> {
  try {
    return await CrossDrop.pickFiles();
  } catch (e) {
    Alert.alert(
      'Couldn’t open files',
      e instanceof Error ? e.message : 'Try again.',
    );
    return [];
  }
}
