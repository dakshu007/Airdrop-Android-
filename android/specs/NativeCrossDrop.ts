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
  /**
   * filesJson is a JSON SharedFile[]; optionsJson a JSON SendOptions ('{}' for none),
   * e.g. {"expiresAfter": 3600}. Resolves to the new transfer id.
   */
  sendFiles(deviceId: string, filesJson: string, optionsJson: string): Promise<string>;
  /**
   * "Send when nearby": queues files for a paired device that isn't reachable now.
   * Share-sheet files without a lasting grant are copied into app storage (bounded).
   * Resolves to the queue item id; rejects 'queue_full' when over the limit.
   */
  queueFiles(deviceId: string, filesJson: string, optionsJson: string): Promise<string>;
  /** Queues the shared link / text for a paired device. Resolves to the queue item id. */
  queueSharedText(deviceId: string): Promise<string>;
  /** Removes a queued item (and CrossDrop's copies of its files). */
  cancelQueued(queueId: string): void;
  /** A failed queued item waits again and goes as soon as the device is reachable. */
  retryQueued(queueId: string): void;
  /** Answers a Mac's photo request: mode 'photo' (camera) or 'pick' (photo picker). Resolves true when opened. */
  startCapture(requestId: string, mode: string): Promise<boolean>;
  /** Forgets a photo request (the Mac is not told). */
  declineCapture(requestId: string): void;
  /** The capture screen was shown or closed: clears Snapshot.captureFocus. */
  clearCaptureFocus(): void;
  openPocketItem(id: string): void;
  /** Re-shares a Pocket item through the Android share sheet. Resolves false when it is gone. */
  sharePocketItem(id: string): Promise<boolean>;
  /** Removes a Pocket item; deleteFile also deletes the saved file. Resolves false when that wasn't possible. */
  removePocketItem(id: string, deleteFile: boolean): Promise<boolean>;
  /** Copies Snapshot.clip to the clipboard. Resolves false when it has expired. */
  copyClip(): Promise<boolean>;
  dismissClip(): void;
  /** Hosts a Drip Room for 30, 60, 120 or 240 minutes. Resolves to the invite URI. */
  startRoom(name: string, minutes: number): Promise<string>;
  /** Joins the room in a scanned code. Resolves to JSON {"name": string, "hostName": string | null}. */
  joinRoom(code: string): Promise<string>;
  /** Leaves (or ends, when hosting) the current room; trust from it ends too. */
  leaveRoom(): void;
  /** The hosted room's QR code as a base64 PNG (no data: prefix). Rejects 'no_room'. */
  roomQrPng(sizePx: number): Promise<string>;
  /** The widget's device was handled: clears Snapshot.pendingTarget. */
  clearPendingTarget(): void;
  /** Sends the shared link / text (from the share sheet or clipboard). Resolves to the new transfer id. */
  sendSharedText(deviceId: string): Promise<string>;
  /** Reads the clipboard once and offers it for sending. Resolves false when it holds nothing usable. */
  takeClipboard(): Promise<boolean>;
  /** Opens the camera to read a pairing QR code. Resolves to the code text, or '' when cancelled. */
  scanPairingCode(): Promise<string>;
  /** Pairs with the device in a scanned code (or joins a Drip Room code). Resolves to its name (or the room's). */
  pairWithCode(code: string, mine: boolean): Promise<string>;
  /** "Send again" from history; deviceId '' means the same device as before. Resolves to the new transfer id. */
  resendHistory(historyId: string, deviceId: string): Promise<string>;
  /** Opens a received http(s) link in the browser. */
  openLink(url: string): void;
  copyText(text: string): void;
  /** Turns the screenshot suggestion on or off, asking for photo access when needed. Resolves to the new state. */
  setScreenshotOffer(enabled: boolean): Promise<boolean>;
  /** Experimental: starts / stops a local-only hotspot the Mac can join (Android 13+). Resolves to whether it is starting. */
  setHotspot(enabled: boolean): Promise<boolean>;
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
  /** Persists a local preference: 'sound' | 'haptics' | 'welcomed' | 'sortByType' | 'turbo'. */
  setPreference(key: string, value: boolean): void;
  /** 'tick' | 'confirm' | 'done' | 'error'. Honours the sound and haptics preferences. */
  feedback(kind: string): void;
  /** Opens the system Wi-Fi panel (or Wi-Fi settings). */
  openWifiSettings(): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('CrossDrop');
