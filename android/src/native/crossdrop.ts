import { DeviceEventEmitter, EmitterSubscription } from 'react-native';
import NativeCrossDrop from '../../specs/NativeCrossDrop';
import type {
  FeedbackKind,
  NotificationPermission,
  PreferenceKey,
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
): Promise<string> {
  return NativeCrossDrop.sendFiles(deviceId, JSON.stringify(files));
}

export async function requestNotificationPermission(): Promise<NotificationPermission> {
  return (await NativeCrossDrop.requestNotificationPermission()) as NotificationPermission;
}

export const startDiscovery = () => NativeCrossDrop.startDiscovery();
export const stopDiscovery = () => NativeCrossDrop.stopDiscovery();
export const setReceiving = (enabled: boolean) =>
  NativeCrossDrop.setReceiving(enabled);
export const respondToPairing = (sessionId: string, accept: boolean) =>
  NativeCrossDrop.respondToPairing(sessionId, accept);
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
