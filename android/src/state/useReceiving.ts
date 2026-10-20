import { useCallback } from 'react';
import { Alert } from 'react-native';
import * as CrossDrop from '../native/crossdrop';
import type { Snapshot } from '../native/types';

function askForNotificationsThen(next: () => void) {
  Alert.alert(
    'Allow notifications?',
    'CrossDrop shows a notification while it is receiving and when files arrive. File names stay hidden on the lock screen.',
    [
      { text: 'Not now', style: 'cancel', onPress: next },
      {
        text: 'Continue',
        onPress: () => {
          CrossDrop.requestNotificationPermission()
            .catch(() => undefined)
            .finally(next);
        },
      },
    ],
    { cancelable: false },
  );
}

/** Turns Receiving on or off, explaining notifications the first time it is switched on. */
export function useReceivingToggle(snapshot: Snapshot) {
  const permission = snapshot.notificationPermission;
  return useCallback(
    (value: boolean) => {
      if (value && permission === 'undetermined') {
        askForNotificationsThen(() => CrossDrop.setReceiving(true));
        return;
      }
      CrossDrop.setReceiving(value);
    },
    [permission],
  );
}
