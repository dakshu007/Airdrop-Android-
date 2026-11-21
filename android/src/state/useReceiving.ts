import { useCallback } from 'react';
import * as CrossDrop from '../native/crossdrop';
import type { ReceiveMode, Snapshot } from '../native/types';

type Listener = (next: () => void) => void;
let listener: Listener | null = null;

/** Lets <NotificationPrompt/> (rendered once by the navigator) show the explainer. */
export function setNotificationPromptListener(l: Listener | null) {
  listener = l;
}

/** Explains notifications in an in-app sheet, asks Android, then continues either way. */
function askForNotificationsThen(next: () => void) {
  if (listener) {
    listener(next);
  } else {
    CrossDrop.requestNotificationPermission()
      .catch(() => undefined)
      .finally(next);
  }
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

/** Sets the receive mode, explaining notifications the first time receiving is switched on. */
export function useReceiveMode(snapshot: Snapshot) {
  const permission = snapshot.notificationPermission;
  return useCallback(
    (mode: ReceiveMode) => {
      if (mode !== 'off' && permission === 'undetermined') {
        askForNotificationsThen(() => CrossDrop.setReceiveMode(mode));
        return;
      }
      CrossDrop.setReceiveMode(mode);
    },
    [permission],
  );
}
