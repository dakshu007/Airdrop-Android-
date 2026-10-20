/**
 * Shapes of the JSON exchanged with the Kotlin engine (see specs/NativeCrossDrop.ts).
 * Kotlin side: android/android/app/src/main/java/com/crossdrop/bridge/SnapshotJson.kt.
 * Keep both in sync. Timestamps are epoch milliseconds.
 */

export type Platform = 'android' | 'macos';

export type NotificationPermission =
  | 'granted'
  | 'denied'
  | 'undetermined'
  | 'notRequired';

export interface LocalDevice {
  deviceId: string;
  name: string;
  /** 64 hex chars; shown grouped for manual verification. */
  fingerprint: string;
}

export interface ReceivingState {
  enabled: boolean;
  /** Set while the listener is up. */
  port: number | null;
  /** Error code when receiving could not start: 'no_network' | 'listen_failed' | 'nsd_failed'. */
  error: string | null;
  /** When receiving switches itself off to save battery (null while a transfer is running). */
  autoOffAt: number | null;
}

export interface DiscoveryState {
  active: boolean;
  /** 'no_network' | 'nsd_failed' | null */
  error: string | null;
}

export interface NetworkState {
  /** True when a Wi-Fi or Ethernet network suitable for local transfer is up. */
  localNetwork: boolean;
}

export interface NearbyDevice {
  deviceId: string;
  name: string;
  platform: Platform;
  trusted: boolean;
}

export interface TrustedDevice {
  deviceId: string;
  name: string;
  platform: Platform;
  fingerprint: string;
  pairedAt: number;
  lastUsedAt: number | null;
  autoAccept: boolean;
}

export type TransferStatus =
  | 'preparing' // sender hashing files
  | 'connecting'
  | 'pairing' // waiting for both users to confirm the code
  | 'waitingForAcceptance' // sender waiting for the receiver's decision
  | 'awaitingYourApproval' // receiver: an offer is waiting on this device
  | 'transferring'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'rejected';

export interface TransferFile {
  name: string;
  size: number;
  mime: string | null;
  /** Bytes moved for this file. */
  bytes: number;
  /** For received files once saved: content URI to open. */
  uri: string | null;
}

export interface TransferError {
  /** A protocol error code (docs/protocol-v1.md §6.4) or a local one:
   * 'unreachable' | 'connection_lost' | 'file_unreadable' | 'no_network' | 'peer_changed_identity'. */
  code: string;
  message: string | null;
}

export interface Transfer {
  id: string;
  direction: 'outgoing' | 'incoming';
  peerId: string;
  peerName: string;
  peerPlatform: Platform;
  status: TransferStatus;
  files: TransferFile[];
  totalBytes: number;
  bytesTransferred: number;
  /** Smoothed rate, null until there is enough data to be meaningful. */
  bytesPerSecond: number | null;
  startedAt: number;
  updatedAt: number;
  error: TransferError | null;
  /** Rejection reason when status is 'rejected'. */
  rejectReason: string | null;
  canRetry: boolean;
}

export interface PairingPrompt {
  sessionId: string;
  peerId: string;
  peerName: string;
  peerPlatform: Platform;
  /** Six digits, e.g. "309997". */
  code: string;
  /** 'sender' when this device started the connection. */
  role: 'sender' | 'receiver';
  /** True after this user confirmed and we are waiting for the other device. */
  waitingForPeer: boolean;
  expiresAt: number;
}

export interface IncomingOffer {
  transferId: string;
  peerId: string;
  peerName: string;
  peerPlatform: Platform;
  files: { name: string; size: number; mime: string | null }[];
  totalBytes: number;
  expiresAt: number;
}

export interface HistoryEntry {
  id: string;
  direction: 'outgoing' | 'incoming';
  peerName: string;
  peerPlatform: Platform;
  status: 'completed' | 'failed' | 'cancelled' | 'rejected';
  files: { name: string; size: number; uri: string | null }[];
  totalBytes: number;
  finishedAt: number;
  errorCode: string | null;
}

export interface SharedFile {
  uri: string;
  name: string;
  /** null when the provider does not report a size. */
  size: number | null;
  mime: string | null;
}

export interface Preferences {
  /** Soft sound when a transfer finishes and is verified. */
  sound: boolean;
  /** Light haptic ticks for pairing codes and finished transfers. */
  haptics: boolean;
  /** True once the welcome screen has been dismissed. */
  welcomed: boolean;
}

export type PreferenceKey = keyof Preferences;

/** 'tick' when a code digit lands, 'confirm' for a confirmed code, 'done' and 'error' when a transfer ends. */
export type FeedbackKind = 'tick' | 'confirm' | 'done' | 'error';

export interface Snapshot {
  local: LocalDevice;
  receiving: ReceivingState;
  discovery: DiscoveryState;
  network: NetworkState;
  nearby: NearbyDevice[];
  trusted: TrustedDevice[];
  /** Active transfers plus ones finished during this app session (until dismissed). */
  transfers: Transfer[];
  pairing: PairingPrompt[];
  offers: IncomingOffer[];
  /** Newest first, at most 200. */
  history: HistoryEntry[];
  /** Files handed over by the Android share sheet and not yet sent or cleared. */
  shared: SharedFile[];
  notificationPermission: NotificationPermission;
  /** Human-readable destination, e.g. "Download/CrossDrop". */
  destinationLabel: string;
  /** Native app version, e.g. "0.1.0". */
  appVersion: string;
  /** Local preferences; nothing here leaves the device. */
  prefs: Preferences;
}
