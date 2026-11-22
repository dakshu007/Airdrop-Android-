import type { SendOptions, SharedFile } from '../native/types';

/**
 * What was handed to each outgoing transfer started in this app session, so a
 * send that fails because the device isn't reachable can be queued ("Send
 * when nearby") without choosing the files again. Kept in memory only and
 * bounded; nothing here is persisted.
 */
export interface RememberedSend {
  deviceId: string;
  files: SharedFile[];
  options: SendOptions;
}

const LIMIT = 20;
const sends = new Map<string, RememberedSend>();

export function rememberSend(transferId: string, send: RememberedSend): void {
  sends.delete(transferId);
  sends.set(transferId, send);
  while (sends.size > LIMIT) {
    const oldest = sends.keys().next().value;
    if (oldest === undefined) break;
    sends.delete(oldest);
  }
}

export function recallSend(transferId: string): RememberedSend | undefined {
  return sends.get(transferId);
}

export function forgetSend(transferId: string): void {
  sends.delete(transferId);
}
