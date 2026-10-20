import {
  countdown,
  countdownCoarse,
  etaSeconds,
  filesTitle,
  formatBytes,
  formatEta,
  formatPairingCode,
  formatRate,
  groupFingerprint,
  pluralFiles,
  relativeTime,
  spokenPairingCode,
  sumSizes,
} from '../src/format';

describe('formatBytes', () => {
  it.each([
    [0, '0 B'],
    [999, '999 B'],
    [1000, '1 KB'],
    [1536, '1.5 KB'],
    [12_345_678, '12.3 MB'],
    [123_456_789, '123 MB'],
    [999_999, '1 MB'],
    [1_000_000_000, '1 GB'],
    [-1, '—'],
    [Number.NaN, '—'],
  ])('%p → %p', (input, expected) => {
    expect(formatBytes(input)).toBe(expected);
  });
});

test('formatRate', () => {
  expect(formatRate(8_100_000)).toBe('8.1 MB/s');
});

describe('etaSeconds', () => {
  it('needs a positive rate', () => {
    expect(etaSeconds(1000, null)).toBeNull();
    expect(etaSeconds(1000, 0)).toBeNull();
  });
  it('rejects absurd estimates', () => {
    expect(etaSeconds(1e15, 1)).toBeNull();
  });
  it('divides remaining by rate', () => {
    expect(etaSeconds(10_000, 1000)).toBe(10);
  });
});

describe('formatEta', () => {
  it.each([
    [2, 'A few seconds left'],
    [12.4, 'About 12 s left'],
    [125, 'About 2 min left'],
    [3600, 'About 1 h left'],
    [5400, 'About 1 h 30 min left'],
  ])('%p s → %p', (input, expected) => {
    expect(formatEta(input)).toBe(expected);
  });
});

describe('relativeTime', () => {
  const now = new Date(2026, 9, 20, 12, 0, 0).getTime();
  it.each([
    [now - 10_000, 'Just now'],
    [now - 5 * 60_000, '5 min ago'],
    [now - 3 * 3600_000, '3 h ago'],
    [now - 26 * 3600_000, 'Yesterday'],
    [now - 3 * 86400_000, '3 days ago'],
    [new Date(2026, 0, 2, 9, 0).getTime(), '2 Jan 2026'],
  ])('%p → %p', (ts, expected) => {
    expect(relativeTime(ts, now)).toBe(expected);
  });
});

test('pairing code formatting', () => {
  expect(formatPairingCode('309997')).toBe('309 997');
  expect(formatPairingCode('12')).toBe('12');
  expect(spokenPairingCode('309997')).toBe('3 0 9, 9 9 7');
});

test('groupFingerprint', () => {
  expect(groupFingerprint('ABCDEF0123456789')).toBe('abcd ef01 2345 6789');
  expect(groupFingerprint('abcde')).toBe('abcd e');
});

test('countdown', () => {
  expect(countdown(119_100)).toBe('2:00');
  expect(countdown(61_000)).toBe('1:01');
  expect(countdown(-5)).toBe('0:00');
  expect(countdownCoarse(119_100)).toBe('2 min');
  expect(countdownCoarse(61_000)).toBe('2 min');
  expect(countdownCoarse(60_000)).toBe('60 s');
  expect(countdownCoarse(42_000)).toBe('50 s');
  expect(countdownCoarse(3_000)).toBe('10 s');
});

test('files helpers', () => {
  expect(pluralFiles(1)).toBe('1 file');
  expect(pluralFiles(3)).toBe('3 files');
  expect(filesTitle([])).toBe('No files');
  expect(filesTitle([{ name: 'a.jpg' }])).toBe('a.jpg');
  expect(filesTitle([{ name: 'a.jpg' }, { name: 'b' }, { name: 'c' }])).toBe(
    'a.jpg and 2 more',
  );
  expect(sumSizes([{ size: 10 }, { size: null }, { size: 5 }])).toEqual({
    total: 15,
    unknown: true,
  });
});
