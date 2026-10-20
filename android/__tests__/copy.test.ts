import {
  ERROR_COPY,
  friendlyError,
  rejectReason,
  REJECT_COPY,
  statusLabel,
} from '../src/copy';

// Every code in docs/protocol-v1.md §6.4, the local codes in src/native/types.ts,
// and the receiving/discovery codes must have dedicated copy.
const PROTOCOL_CODES = [
  'bad_frame',
  'frame_too_large',
  'bad_message',
  'unexpected_message',
  'unsupported_version',
  'auth_failed',
  'pairing_required',
  'pairing_rejected',
  'busy',
  'not_receiving',
  'integrity_failed',
  'insufficient_storage',
  'storage_error',
  'timeout',
  'internal',
];
const LOCAL_CODES = [
  'unreachable',
  'connection_lost',
  'file_unreadable',
  'no_network',
  'peer_changed_identity',
];
const SERVICE_CODES = ['listen_failed', 'nsd_failed'];

test.each([...PROTOCOL_CODES, ...LOCAL_CODES, ...SERVICE_CODES])(
  '%s has copy',
  code => {
    expect(ERROR_COPY[code]).toBeDefined();
    expect(ERROR_COPY[code].title.length).toBeGreaterThan(0);
    expect(ERROR_COPY[code].detail.length).toBeGreaterThan(0);
  },
);

test('unknown codes fall back to a generic message', () => {
  expect(friendlyError('nope')).toBe(ERROR_COPY.internal);
  expect(friendlyError(null)).toBe(ERROR_COPY.internal);
});

test.each([
  'declined',
  'busy',
  'insufficient_storage',
  'timeout',
  'not_receiving',
])('reject reason %s has copy', reason => {
  expect(rejectReason(reason)).toBe(REJECT_COPY[reason]);
});

test('status labels depend on direction', () => {
  expect(statusLabel('transferring', 'outgoing')).toBe('Sending');
  expect(statusLabel('transferring', 'incoming')).toBe('Receiving');
  expect(statusLabel('completed', 'incoming')).toBe('Received');
});
