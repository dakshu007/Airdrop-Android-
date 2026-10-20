import { useCallback, useState } from 'react';
import { Alert } from 'react-native';
import { useNavigation } from '../navigation/NavigationContext';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice, SharedFile } from '../native/types';

/**
 * Starts a transfer and moves to Activity, where progress is shown.
 * Returns `busy` while the native side is accepting the request.
 */
export function useSendFiles() {
  const { navigate } = useNavigation();
  const [busy, setBusy] = useState(false);

  const send = useCallback(
    async (device: NearbyDevice, files: SharedFile[]): Promise<boolean> => {
      if (files.length === 0) {
        return false;
      }
      setBusy(true);
      try {
        await CrossDrop.sendFiles(device.deviceId, files);
        navigate('activity');
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
    [navigate],
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
