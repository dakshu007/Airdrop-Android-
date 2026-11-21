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
  /** 'off' | 'mine' (paired devices only, always on) | 'everyone' (for 10 minutes). */
  setReceiveMode(mode: string): void;
  /** Opens the system document picker. Resolves to a JSON SharedFile[] (empty when cancelled). */
  pickFiles(): Promise<string>;
  /** Opens the system folder picker. Resolves to a JSON SharedFile[] with folder paths (empty when cancelled). */
  pickFolder(): Promise<string>;
  /** filesJson is a JSON SharedFile[]. Resolves to the new transfer id. */
  sendFiles(deviceId: string, filesJson: string): Promise<string>;
  /** Sends the shared link / text (from the share sheet or clipboard). Resolves to the new transfer id. */
  sendSharedText(deviceId: string): Promise<string>;
  /** Reads the clipboard once and offers it for sending. Resolves false when it holds nothing usable. */
  takeClipboard(): Promise<boolean>;
  /** Opens the camera to read a pairing QR code. Resolves to the code text, or '' when cancelled. */
  scanPairingCode(): Promise<string>;
  /** Pairs with the device in a scanned code. Resolves to its name. */
  pairWithCode(code: string, mine: boolean): Promise<string>;
  /** "Send again" from history; deviceId '' means the same device as before. Resolves to the new transfer id. */
  resendHistory(historyId: string, deviceId: string): Promise<string>;
  /** Opens a received http(s) link in the browser. */
  openLink(url: string): void;
  copyText(text: string): void;
  /** Turns the screenshot suggestion on or off, asking for photo access when needed. Resolves to the new state. */
  setScreenshotOffer(enabled: boolean): Promise<boolean>;
  /** mine: "This is my device" — its transfers are accepted without asking from now on. */
  respondToPairing(sessionId: string, accept: boolean, mine: boolean): void;
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
  /** Persists a local preference: 'sound' | 'haptics' | 'welcomed'. */
  setPreference(key: string, value: boolean): void;
  /** 'tick' | 'confirm' | 'done' | 'error'. Honours the sound and haptics preferences. */
  feedback(kind: string): void;
  /** Opens the system Wi-Fi panel (or Wi-Fi settings). */
  openWifiSettings(): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('CrossDrop');
