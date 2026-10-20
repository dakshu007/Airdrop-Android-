import type {TurboModule} from 'react-native';
import {TurboModuleRegistry} from 'react-native';

/**
 * Bridge to the Kotlin CrossDrop engine. File bytes never cross this bridge:
 * JS only passes content URIs and receives state snapshots.
 *
 * Structured values travel as JSON strings so the contract stays stable and
 * easy to validate on both sides. The shapes are defined in
 * src/native/types.ts. State changes arrive as `CrossDropState` device events
 * whose payload is `{json: string}` holding a full Snapshot.
 */
export interface Spec extends TurboModule {
  getSnapshot(): Promise<string>;
  startDiscovery(): void;
  stopDiscovery(): void;
  setReceiving(enabled: boolean): void;
  /** Opens the system document picker. Resolves to a JSON SharedFile[] (empty when cancelled). */
  pickFiles(): Promise<string>;
  /** filesJson is a JSON SharedFile[]. Resolves to the new transfer id. */
  sendFiles(deviceId: string, filesJson: string): Promise<string>;
  respondToPairing(sessionId: string, accept: boolean): void;
  respondToOffer(transferId: string, accept: boolean): void;
  cancelTransfer(transferId: string): void;
  dismissTransfer(transferId: string): void;
  /** Re-sends a failed or cancelled outgoing transfer from this app session. Resolves to the new transfer id. */
  retryTransfer(transferId: string): Promise<string>;
  forgetDevice(deviceId: string): void;
  setAutoAccept(deviceId: string, enabled: boolean): void;
  setDeviceName(name: string): void;
  clearSharedFiles(): void;
  clearHistory(): void;
  openFile(uri: string): void;
  openDownloads(): void;
  /** Resolves to a NotificationPermission value. */
  requestNotificationPermission(): Promise<string>;
  openAppSettings(): void;
  /** Persists the wallpaper choice ('auto' or a wallpaper name). */
  setWallpaper(name: string): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('CrossDrop');
