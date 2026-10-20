import type { Platform, TransferStatus } from './native/types';

/** User-facing copy. Error codes come from docs/protocol-v1.md §6.4 and src/native/types.ts. */

export interface FriendlyError {
  title: string;
  detail: string;
}

export const ERROR_COPY: Record<string, FriendlyError> = {
  // Protocol errors (§6.4)
  bad_frame: {
    title: 'Connection problem',
    detail:
      'The other device sent data CrossDrop could not read. Try again; if it keeps happening, update CrossDrop on both devices.',
  },
  frame_too_large: {
    title: 'Connection problem',
    detail:
      'The other device sent more data than allowed at once. Update CrossDrop on both devices and try again.',
  },
  bad_message: {
    title: 'Connection problem',
    detail:
      'The other device sent a message CrossDrop could not understand. Update CrossDrop on both devices.',
  },
  unexpected_message: {
    title: 'Connection problem',
    detail: 'The devices got out of step. Try sending again.',
  },
  unsupported_version: {
    title: 'Update needed',
    detail:
      'These devices run incompatible versions of CrossDrop. Update both to the latest version.',
  },
  auth_failed: {
    title: 'Could not verify the device',
    detail:
      'The other device could not prove its identity, so nothing was sent. If you reinstalled CrossDrop on it, forget it and pair again.',
  },
  pairing_required: {
    title: 'Pairing needed',
    detail:
      'The other device no longer recognises this phone. Send again to pair with a new code.',
  },
  pairing_rejected: {
    title: 'Pairing cancelled',
    detail:
      'The code was not confirmed on both devices, so they were not paired.',
  },
  busy: {
    title: 'Device is busy',
    detail:
      'The other device is handling other transfers. Try again in a moment.',
  },
  not_receiving: {
    title: 'Receiving is off',
    detail: 'Turn on Receiving on the other device, then try again.',
  },
  integrity_failed: {
    title: 'File check failed',
    detail:
      'A file arrived damaged and was deleted. Try sending again, ideally with a stronger Wi-Fi signal.',
  },
  insufficient_storage: {
    title: 'Not enough storage',
    detail: 'There is not enough free space on the receiving device.',
  },
  storage_error: {
    title: 'Could not save',
    detail:
      'The receiving device could not write the file to its destination folder.',
  },
  timeout: {
    title: 'Timed out',
    detail:
      'The other device stopped responding. Check both devices are awake and on the same Wi-Fi.',
  },
  internal: {
    title: 'Something went wrong',
    detail: 'An unexpected error stopped the transfer. Try again.',
  },
  cancelled: {
    title: 'Cancelled',
    detail: 'The transfer was cancelled.',
  },
  // Local errors (types.ts)
  unreachable: {
    title: 'Device not reachable',
    detail:
      'Make sure both devices are on the same Wi-Fi. Guest networks and some office networks stop devices from reaching each other.',
  },
  connection_lost: {
    title: 'Connection lost',
    detail:
      'The connection dropped during the transfer. Files that finished were kept; send the rest again.',
  },
  file_unreadable: {
    title: 'Could not read a file',
    detail:
      'One of the files is no longer available. It may have been moved, deleted, or the app that shared it revoked access.',
  },
  no_network: {
    title: 'No Wi-Fi connection',
    detail: 'Connect to the same Wi-Fi network as the other device.',
  },
  peer_changed_identity: {
    title: 'Device identity changed',
    detail:
      'This device presented a different identity than the one you paired with. Nothing was sent. If CrossDrop was reinstalled there, forget the device and pair again.',
  },
  // Receiving / discovery
  listen_failed: {
    title: 'Could not start receiving',
    detail:
      'CrossDrop could not open a network port. Try turning Receiving off and on again.',
  },
  nsd_failed: {
    title: 'Nearby discovery unavailable',
    detail:
      'Android’s network discovery service did not respond. Try again, or toggle Wi-Fi off and on.',
  },
};

export function friendlyError(code: string | null | undefined): FriendlyError {
  if (code && ERROR_COPY[code]) {
    return ERROR_COPY[code];
  }
  return ERROR_COPY.internal;
}

export const REJECT_COPY: Record<string, string> = {
  declined: 'Declined by the other device.',
  busy: 'The other device was busy.',
  insufficient_storage: 'Not enough space on the other device.',
  timeout: 'No answer from the other device in time.',
  not_receiving: 'Receiving is turned off on the other device.',
};

export function rejectReason(reason: string | null | undefined): string {
  return (
    (reason && REJECT_COPY[reason]) ||
    'The other device did not accept the files.'
  );
}

export function statusLabel(
  status: TransferStatus,
  direction: 'outgoing' | 'incoming',
): string {
  switch (status) {
    case 'preparing':
      return 'Preparing…';
    case 'connecting':
      return 'Connecting…';
    case 'pairing':
      return 'Confirm the pairing code';
    case 'waitingForAcceptance':
      return 'Waiting for the other device to accept…';
    case 'awaitingYourApproval':
      return 'Waiting for your approval';
    case 'transferring':
      return direction === 'outgoing' ? 'Sending' : 'Receiving';
    case 'completed':
      return direction === 'outgoing' ? 'Sent' : 'Received';
    case 'failed':
      return 'Failed';
    case 'cancelled':
      return 'Cancelled';
    case 'rejected':
      return 'Not accepted';
  }
}

export function platformLabel(platform: Platform): string {
  return platform === 'macos' ? 'Mac' : 'Android';
}

export const FINAL_STATUSES: TransferStatus[] = [
  'completed',
  'failed',
  'cancelled',
  'rejected',
];

export function isFinal(status: TransferStatus): boolean {
  return FINAL_STATUSES.includes(status);
}
