/**
 * Shapes of the JSON exchanged with the Kotlin engine (see specs/NativeCrossDrop.ts).
 * Kotlin side: android/android/app/src/main/java/com/crossdrop/engine/Snapshots.kt.
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

/** 'mine': only paired devices, always on and invisible to others; 'everyone': anyone nearby, for 10 minutes. */
export type ReceiveMode = 'off' | 'mine' | 'everyone';

export interface ReceivingState {
  enabled: boolean;
  mode: ReceiveMode;
  /** What receiving returns to when the 'everyone' window closes. */
  base: 'off' | 'mine';
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
  /** Paired but not found by discovery; CrossDrop will try the address that last worked. */
  remembered: boolean;
  /** Says it is in this phone's Drip Room (a hint; pairing through the room proves it). */
  inRoom: boolean;
}

/** 'files', or a link / text handed off without being saved as a file. */
export type TransferKind = 'files' | 'link' | 'text';

export interface TrustedDevice {
  deviceId: string;
  name: string;
  platform: Platform;
  fingerprint: string;
  pairedAt: number;
  lastUsedAt: number | null;
  autoAccept: boolean;
  /** Temporary trust from a Drip Room ends at this time; null = paired for good. */
  expiresAt: number | null;
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
  kind: TransferKind;
  /** Received (or sent) link / text; this app session only. */
  text: string | null;
  /** Expiring drop: seconds after which the sender asked for deletion (null = keep). */
  expiresAfter: number | null;
  /** Incoming expiring drop: when CrossDrop deletes the saved files (outgoing: when the receiver was asked to). */
  deleteAt: number | null;
  /** Connections used; more than 1 with Turbo. */
  streams: number;
  /** Set when this transfer delivers a "send when nearby" item. */
  queueId: string | null;
  /** True for a photo sent back for (or received from) a capture request. */
  answersCapture: boolean;
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
  kind: TransferKind;
  /** The sender asks for deletion this many seconds after receiving (a courtesy, not enforced). */
  expiresAfter: number | null;
  /** Answers a photo request this device sent; accepted without asking. */
  answersCapture: boolean;
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
  peerId: string | null;
  kind: TransferKind;
  /** The link, for link entries. Text content is never kept in history. */
  link: string | null;
  canSendAgain: boolean;
  /** Expiring drop: incoming — when CrossDrop deletes (or deleted) the files; outgoing — when the receiver was asked to. */
  deleteAt: number | null;
}

export interface SharedFile {
  uri: string;
  name: string;
  /** null when the provider does not report a size. */
  size: number | null;
  mime: string | null;
  /** Folder path inside a picked folder, e.g. "Trip/Day 1"; '' for a plain file. */
  path?: string;
}

/** A link or short text from the share sheet or the clipboard, waiting to be sent. */
export interface SharedText {
  kind: 'link' | 'text';
  /** First 500 characters. */
  preview: string;
  length: number;
}

export interface Preferences {
  /** Soft sound when a transfer finishes and is verified. */
  sound: boolean;
  /** Light haptic ticks for pairing codes and finished transfers. */
  haptics: boolean;
  /** True once the welcome screen has been dismissed. */
  welcomed: boolean;
  /** Offer to send each new screenshot to the last device used. */
  screenshotOffer: boolean;
  /** Smart arrival: images, videos and audio go to Pictures, Movies and Music › CrossDrop. */
  sortByType: boolean;
  /** Turbo (experimental): multi-file sends ask for parallel connections. */
  turbo: boolean;
}

export interface HotspotState {
  state: 'off' | 'starting' | 'on' | 'failed' | 'unsupported';
  ssid: string | null;
  password: string | null;
  error: string | null;
}

export type PreferenceKey =
  | 'sound'
  | 'haptics'
  | 'welcomed'
  | 'sortByType'
  | 'turbo';

/** Per-send options passed with sendFiles / queueFiles. */
export interface SendOptions {
  /** Ask the receiver to delete the files after this many seconds (60 … 2 592 000). */
  expiresAfter?: number;
}

/** A "send when nearby" item waiting for a paired device. */
export interface QueuedSend {
  id: string;
  deviceId: string;
  deviceName: string;
  devicePlatform: Platform | null;
  /** False when the device was forgotten since; the item can only be cancelled. */
  paired: boolean;
  kind: TransferKind;
  files: { name: string; size: number | null; mime: string | null; copied: boolean }[];
  /** First 200 characters of a queued link / text. */
  preview: string | null;
  totalBytes: number;
  createdAt: number;
  status: 'waiting' | 'sending' | 'failed';
  /** For 'failed': a protocol error code, 'rejected' or 'file_unreadable'. */
  error: string | null;
  attempts: number;
  /** The running transfer while 'sending'. */
  transferId: string | null;
  expiresAfter: number | null;
}

export interface QueueStorage {
  /** Bytes held in CrossDrop's own copies of queued share-sheet files. */
  usedBytes: number;
  limitBytes: number;
  /** True during the short discovery window that looks for queued devices. */
  searching: boolean;
}

/** A paired Mac asked this phone for a photo. */
export interface CaptureRequestInfo {
  requestId: string;
  peerId: string;
  peerName: string;
  /** 'photo': take a new one; 'pick': choose existing ones. */
  kind: 'photo' | 'pick';
  expiresAt: number;
  /** 'sending' while the answer is on its way. */
  state: 'open' | 'sending';
}

/** A recently received file (newest first, at most 30). */
export interface PocketItem {
  id: string;
  uri: string;
  name: string;
  size: number;
  mime: string | null;
  receivedAt: number;
  from: string;
  fromPlatform: Platform;
  /** Expiring drop: when CrossDrop deletes it. */
  deleteAt: number | null;
}

/** Text that just arrived from a paired Mac: offered for pasting for two minutes. */
export interface Clip {
  transferId: string;
  from: string;
  fromPlatform: Platform;
  preview: string;
  length: number;
  expiresAt: number;
}

/** A device tapped on the home-screen widget: open the file picker for it. */
export interface PendingTarget {
  deviceId: string;
  name: string;
  platform: Platform;
  at: number;
}

/** The Drip Room this phone is in. */
export interface RoomInfo {
  id: string;
  name: string;
  expiresAt: number;
  /** This phone shows the code. */
  hosting: boolean;
  /** crossdrop://room?... while hosting, else null. */
  invite: string | null;
  /** Nearby devices that say they are in the room. */
  members: number;
}

/** 'tick' when a code digit lands, 'confirm' for a confirmed code, 'done' and 'error' when a transfer ends. */
export type FeedbackKind = 'tick' | 'confirm' | 'done' | 'error';

export interface Snapshot {
  local: LocalDevice;
  receiving: ReceivingState;
  discovery: DiscoveryState;
  network: NetworkState;
  nearby: NearbyDevice[];
  /** When a device last appeared nearby (epoch ms; 0 = never). */
  newestDeviceAt: number;
  trusted: TrustedDevice[];
  /** Active transfers plus ones finished during this app session (until dismissed). */
  transfers: Transfer[];
  pairing: PairingPrompt[];
  offers: IncomingOffer[];
  /** Newest first, at most 200. */
  history: HistoryEntry[];
  /** Files handed over by the Android share sheet and not yet sent or cleared. */
  shared: SharedFile[];
  sharedText: SharedText | null;
  /** The device files were last sent to. */
  lastDeviceId: string | null;
  /** Photo access for the screenshot suggestion. */
  screenshotPermission: boolean;
  /** Experimental no-router mode: a local-only hotspot the Mac joins. */
  hotspot: HotspotState;
  notificationPermission: NotificationPermission;
  /** Human-readable destination, e.g. "Download/CrossDrop". */
  destinationLabel: string;
  /** Native app version, e.g. "0.1.0". */
  appVersion: string;
  /** Local preferences; nothing here leaves the device. */
  prefs: Preferences;
  /** "Send when nearby" items, oldest first. */
  queue: QueuedSend[];
  queueStorage: QueueStorage;
  /** Photo requests from paired Macs. */
  captureRequests: CaptureRequestInfo[];
  /** The request whose capture screen should be shown (opened from its notification). */
  captureFocus: string | null;
  /** Recent received files. */
  pocket: PocketItem[];
  clip: Clip | null;
  pendingTarget: PendingTarget | null;
  room: RoomInfo | null;
  /** Room lengths offered, in minutes. */
  roomDurations: number[];
}
