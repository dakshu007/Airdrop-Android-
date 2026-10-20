/** Pure formatting helpers. Sizes use SI units (1 KB = 1000 B), like Android's file manager. */

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB'];

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return '—';
  }
  if (bytes < 1000) {
    return `${Math.round(bytes)} B`;
  }
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < UNITS.length - 1) {
    value /= 1000;
    unit++;
  }
  // Avoid "1000 KB": rounding can push the value to the next unit.
  if (value >= 999.5 && unit < UNITS.length - 1) {
    value /= 1000;
    unit++;
  }
  const digits = value < 100 ? 1 : 0;
  const text = value.toFixed(digits).replace(/\.0$/, '');
  return `${text} ${UNITS[unit]}`;
}

export function formatRate(bytesPerSecond: number): string {
  return `${formatBytes(bytesPerSecond)}/s`;
}

/**
 * Seconds left, or null when an estimate would not be meaningful (no rate
 * yet, stalled, or absurdly long).
 */
export function etaSeconds(
  remainingBytes: number,
  bytesPerSecond: number | null,
): number | null {
  if (bytesPerSecond === null || !(bytesPerSecond > 0) || remainingBytes < 0) {
    return null;
  }
  const seconds = remainingBytes / bytesPerSecond;
  if (!Number.isFinite(seconds) || seconds > 24 * 3600) {
    return null;
  }
  return seconds;
}

export function formatEta(seconds: number): string {
  if (seconds < 5) {
    return 'A few seconds left';
  }
  if (seconds < 60) {
    return `About ${Math.round(seconds)} s left`;
  }
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return `About ${minutes} min left`;
  }
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `About ${h} h left` : `About ${h} h ${m} min left`;
}

/** Compact estimate for a small stat tile: "<5 s", "~9 s", "~3 min", "~1 h 20 min". */
export function formatEtaShort(seconds: number): string {
  if (seconds < 5) {
    return '<5 s';
  }
  if (seconds < 60) {
    return `~${Math.round(seconds)} s`;
  }
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return `~${minutes} min`;
  }
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `~${h} h` : `~${h} h ${m} min`;
}

const MONTHS = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

export function formatDate(timestamp: number): string {
  const d = new Date(timestamp);
  return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

export function formatClock(timestamp: number): string {
  const d = new Date(timestamp);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

export function relativeTime(timestamp: number, now: number): string {
  const seconds = Math.max(0, (now - timestamp) / 1000);
  if (seconds < 45) {
    return 'Just now';
  }
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return `${minutes} min ago`;
  }
  const hours = Math.round(minutes / 60);
  if (hours < 24) {
    return `${hours} h ago`;
  }
  const days = Math.round(hours / 24);
  if (days === 1) {
    return 'Yesterday';
  }
  if (days < 7) {
    return `${days} days ago`;
  }
  return formatDate(timestamp);
}

/** "309997" → "309 997" */
export function formatPairingCode(code: string): string {
  const digits = code.replace(/\D/g, '');
  if (digits.length !== 6) {
    return code;
  }
  return `${digits.slice(0, 3)} ${digits.slice(3)}`;
}

/** Spoken form for screen readers: "3 0 9, 9 9 7". */
export function spokenPairingCode(code: string): string {
  const digits = code.replace(/\D/g, '').split('');
  return `${digits.slice(0, 3).join(' ')}, ${digits.slice(3).join(' ')}`;
}

/** Groups a hex fingerprint into blocks of four: "ab12 cd34 …". */
export function groupFingerprint(hex: string): string {
  return (hex.toLowerCase().match(/.{1,4}/g) ?? []).join(' ');
}

export function pluralFiles(count: number): string {
  return count === 1 ? '1 file' : `${count} files`;
}

/**
 * Calm countdown for prompts: whole minutes, then 10-second steps in the last
 * minute ("2 min", "1 min", "50 s" … "10 s"). It changes rarely, so the
 * screen stays still and screen readers aren't interrupted every second.
 */
export function countdownCoarse(msLeft: number): string {
  const s = Math.max(0, msLeft / 1000);
  if (s > 60) {
    return `${Math.ceil(s / 60)} min`;
  }
  return `${Math.max(10, Math.ceil(s / 10) * 10)} s`;
}

export function countdown(msLeft: number): string {
  const total = Math.max(0, Math.ceil(msLeft / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function sumSizes(files: { size: number | null }[]): {
  total: number;
  unknown: boolean;
} {
  let total = 0;
  let unknown = false;
  for (const f of files) {
    if (f.size === null || f.size < 0) {
      unknown = true;
    } else {
      total += f.size;
    }
  }
  return { total, unknown };
}

/** Title for a set of files: "IMG_0042.jpg" or "IMG_0042.jpg and 3 more". */
export function filesTitle(files: { name: string }[]): string {
  if (files.length === 0) {
    return 'No files';
  }
  if (files.length === 1) {
    return files[0].name;
  }
  return `${files[0].name} and ${files.length - 1} more`;
}
