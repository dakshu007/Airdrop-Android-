import { DeviceEventEmitter, EmitterSubscription } from 'react-native';
import NativeCrossDrop from '../../specs/NativeCrossDrop';
import type {
  FeedbackKind,
  NotificationPermission,
  PreferenceKey,
  ReceiveMode,
  SendOptions,
  SharedFile,
  Snapshot,
} from './types';

/** Typed wrapper around the CrossDrop TurboModule. */

export const STATE_EVENT = 'CrossDropState';

export async function getSnapshot(): Promise<Snapshot> {
  return JSON.parse(await NativeCrossDrop.getSnapshot()) as Snapshot;
}

export function subscribe(
  listener: (snapshot: Snapshot) => void,
): EmitterSubscription {
  return DeviceEventEmitter.addListener(
    STATE_EVENT,
    (event: { json: string }) => {
      try {
        listener(JSON.parse(event.json) as Snapshot);
      } catch {
        // A malformed snapshot is dropped; the next one replaces it.
      }
    },
  );
}

export async function pickFiles(): Promise<SharedFile[]> {
  const parsed = JSON.parse(await NativeCrossDrop.pickFiles());
  return Array.isArray(parsed) ? (parsed as SharedFile[]) : [];
}

export function sendFiles(
  deviceId: string,
  files: SharedFile[],
  options: SendOptions = {},
): Promise<string> {
  return NativeCrossDrop.sendFiles(
    deviceId,
    JSON.stringify(files),
    JSON.stringify(options),
  );
}

/** "Send when nearby": resolves to the queue item id; rejects 'queue_full' or 'not_paired'. */
export function queueFiles(
  deviceId: string,
  files: SharedFile[],
  options: SendOptions = {},
): Promise<string> {
  return NativeCrossDrop.queueFiles(
    deviceId,
    JSON.stringify(files),
    JSON.stringify(options),
  );
}

export const queueSharedText = (deviceId: string) =>
  NativeCrossDrop.queueSharedText(deviceId);
export const cancelQueued = (queueId: string) =>
  NativeCrossDrop.cancelQueued(queueId);
export const retryQueued = (queueId: string) =>
  NativeCrossDrop.retryQueued(queueId);

/** Answers a Mac's photo request with the camera ('photo') or the photo picker ('pick'). */
export const startCapture = (requestId: string, mode: 'photo' | 'pick') =>
  NativeCrossDrop.startCapture(requestId, mode);
export const declineCapture = (requestId: string) =>
  NativeCrossDrop.declineCapture(requestId);
export const clearCaptureFocus = () => NativeCrossDrop.clearCaptureFocus();

export const openPocketItem = (id: string) => NativeCrossDrop.openPocketItem(id);
export const sharePocketItem = (id: string) =>
  NativeCrossDrop.sharePocketItem(id);
/** Removes from the Pocket; deleteFile also deletes the saved file. */
export const removePocketItem = (id: string, deleteFile = false) =>
  NativeCrossDrop.removePocketItem(id, deleteFile);

export const copyClip = () => NativeCrossDrop.copyClip();
export const dismissClip = () => NativeCrossDrop.dismissClip();

/** Hosts a Drip Room; resolves to the invite URI. */
export const startRoom = (name: string, minutes: number) =>
  NativeCrossDrop.startRoom(name, minutes);

export async function joinRoom(
  code: string,
): Promise<{ name: string; hostName: string | null }> {
  return JSON.parse(await NativeCrossDrop.joinRoom(code)) as {
    name: string;
    hostName: string | null;
  };
}

export const leaveRoom = () => NativeCrossDrop.leaveRoom();
/** The hosted room's QR code as a data: URI for <Image>. */
export async function roomQrDataUri(sizePx: number): Promise<string> {
  return `data:image/png;base64,${await NativeCrossDrop.roomQrPng(sizePx)}`;
}

export const clearPendingTarget = () => NativeCrossDrop.clearPendingTarget();

export async function requestNotificationPermission(): Promise<NotificationPermission> {
  return (await NativeCrossDrop.requestNotificationPermission()) as NotificationPermission;
}

export const startDiscovery = () => NativeCrossDrop.startDiscovery();
export const stopDiscovery = () => NativeCrossDrop.stopDiscovery();
export const setReceiving = (enabled: boolean) =>
  NativeCrossDrop.setReceiving(enabled);
export const respondToPairing = (
  sessionId: string,
  accept: boolean,
  mine = false,
) => NativeCrossDrop.respondToPairing(sessionId, accept, mine);
export const setReceiveMode = (mode: ReceiveMode) =>
  NativeCrossDrop.setReceiveMode(mode);

export async function pickFolder(): Promise<SharedFile[]> {
  const parsed = JSON.parse(await NativeCrossDrop.pickFolder());
  return Array.isArray(parsed) ? (parsed as SharedFile[]) : [];
}

export const sendSharedText = (deviceId: string) =>
  NativeCrossDrop.sendSharedText(deviceId);
/** Reads the clipboard once (CrossDrop must be on screen). False when it holds nothing usable. */
export const takeClipboard = () => NativeCrossDrop.takeClipboard();
/** Resolves to the scanned code, or '' when cancelled. */
export const scanPairingCode = () => NativeCrossDrop.scanPairingCode();
/** Resolves to the paired device's name. */
export const pairWithCode = (code: string, mine: boolean) =>
  NativeCrossDrop.pairWithCode(code, mine);
export const resendHistory = (historyId: string, deviceId?: string) =>
  NativeCrossDrop.resendHistory(historyId, deviceId ?? '');
export const openLink = (url: string) => NativeCrossDrop.openLink(url);
export const copyText = (text: string) => NativeCrossDrop.copyText(text);
export const setScreenshotOffer = (enabled: boolean) =>
  NativeCrossDrop.setScreenshotOffer(enabled);
export const respondToOffer = (transferId: string, accept: boolean) =>
  NativeCrossDrop.respondToOffer(transferId, accept);
export const cancelTransfer = (transferId: string) =>
  NativeCrossDrop.cancelTransfer(transferId);
export const dismissTransfer = (transferId: string) =>
  NativeCrossDrop.dismissTransfer(transferId);
export const retryTransfer = (transferId: string) =>
  NativeCrossDrop.retryTransfer(transferId);
export const forgetDevice = (deviceId: string) =>
  NativeCrossDrop.forgetDevice(deviceId);
export const setAutoAccept = (deviceId: string, enabled: boolean) =>
  NativeCrossDrop.setAutoAccept(deviceId, enabled);
export const setDeviceName = (name: string) =>
  NativeCrossDrop.setDeviceName(name);
export const clearSharedFiles = () => NativeCrossDrop.clearSharedFiles();
export const clearHistory = () => NativeCrossDrop.clearHistory();
export const openFile = (uri: string) => NativeCrossDrop.openFile(uri);
export const openDownloads = () => NativeCrossDrop.openDownloads();
export const openAppSettings = () => NativeCrossDrop.openAppSettings();
export const openWifiSettings = () => NativeCrossDrop.openWifiSettings();
export const setPreference = (key: PreferenceKey, value: boolean) =>
  NativeCrossDrop.setPreference(key, value);
/** Haptics and the done sound; the engine applies the user's preferences. */
export const feedback = (kind: FeedbackKind) => NativeCrossDrop.feedback(kind);
export const setHotspot = (enabled: boolean) =>
  NativeCrossDrop.setHotspot(enabled);
