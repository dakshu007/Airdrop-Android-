import { Alert } from 'react-native';
import * as CrossDrop from '../native/crossdrop';
import type { SharedFile } from '../native/types';

/**
 * Opens the system file picker; [] when cancelled or unavailable. Sending
 * itself goes through useSendFlow (send now, or "Send when nearby").
 */
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
