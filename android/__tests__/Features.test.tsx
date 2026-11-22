/**
 * Render tests for Send when nearby, Pocket, the clipboard pill, Drip Rooms,
 * photo requests, the widget target, sending options and new settings.
 *
 * @format
 */

import React from 'react';
import { Alert, AlertButton, DeviceEventEmitter } from 'react-native';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';
import NativeCrossDrop from '../specs/NativeCrossDrop';
import type {
  HistoryEntry,
  NearbyDevice,
  PocketItem,
  QueuedSend,
  Snapshot,
} from '../src/native/types';
import { emptySnapshot } from '../test-utils/fixtures';

const native = NativeCrossDrop as jest.Mocked<typeof NativeCrossDrop>;
type Renderer = ReactTestRenderer.ReactTestRenderer;

async function render(snapshot: Snapshot) {
  native.getSnapshot.mockResolvedValue(JSON.stringify(snapshot));
  let renderer: Renderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  await layout(renderer!);
  return renderer!;
}

/** The test renderer never lays out; give every measured box a phone-sized frame. */
async function layout(renderer: Renderer) {
  await ReactTestRenderer.act(async () => {
    renderer.root
      .findAll(node => typeof node.props.onLayout === 'function')
      .forEach(node =>
        node.props.onLayout({
          nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 420 } },
        }),
      );
  });
}

async function emit(renderer: Renderer, snapshot: Snapshot) {
  await ReactTestRenderer.act(async () => {
    DeviceEventEmitter.emit('CrossDropState', {
      json: JSON.stringify(snapshot),
    });
  });
  await layout(renderer);
}

function allText(renderer: Renderer): string {
  return renderer.root
    .findAll(node => (node.type as unknown) === 'Text')
    .map(node => {
      const children = node.props.children;
      return Array.isArray(children) ? children.join('') : String(children);
    })
    .join('\n');
}

/** The last (top-most) pressable with this label. */
function pressable(renderer: Renderer, label: string) {
  const all = renderer.root.findAll(
    node =>
      node.props.accessibilityLabel === label &&
      typeof node.props.onPress === 'function',
  );
  if (all.length === 0) throw new Error(`No pressable labelled “${label}”`);
  return all[all.length - 1];
}

async function press(renderer: Renderer, label: string) {
  await ReactTestRenderer.act(async () =>
    pressable(renderer, label).props.onPress(),
  );
}

async function openTab(renderer: Renderer, label: string) {
  await press(renderer, label);
  await layout(renderer);
}

/** Captures Alert.alert calls; press a button by its text. */
function spyAlert() {
  const calls: { title: string; buttons?: AlertButton[] }[] = [];
  const spy = jest
    .spyOn(Alert, 'alert')
    .mockImplementation((title, _message, buttons) => {
      calls.push({ title: String(title ?? ''), buttons });
    });
  return {
    calls,
    async choose(text: string) {
      const button = calls[calls.length - 1]?.buttons?.find(
        b => b.text === text,
      );
      if (!button?.onPress) throw new Error(`No alert button “${text}”`);
      await ReactTestRenderer.act(async () => {
        await button.onPress!();
      });
    },
    restore: () => spy.mockRestore(),
  };
}

const MAC: NearbyDevice = {
  deviceId: 'abc',
  name: 'Studio Mac',
  platform: 'macos',
  trusted: true,
  remembered: false,
  inRoom: false,
};

const FILE_JSON =
  '[{"uri":"content://x/1","name":"a.txt","size":3,"mime":null}]';

afterEach(() => {
  jest.clearAllMocks();
});

test('offers "Send when nearby" for a paired Mac that isn’t around, and queues', async () => {
  const renderer = await render(
    emptySnapshot({ nearby: [{ ...MAC, remembered: true }] }),
  );
  await press(renderer, 'Studio Mac, Mac, paired, not seen nearby');
  expect(allText(renderer)).toContain('Studio Mac isn’t nearby');
  // Nothing is sent until the user chooses.
  expect(native.sendFiles).not.toHaveBeenCalled();

  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  await press(renderer, 'Send when nearby');
  expect(native.queueFiles).toHaveBeenCalledWith('abc', FILE_JSON, '{}');
  expect(native.feedback).toHaveBeenCalledWith('confirm');
  expect(allText(renderer)).toContain('Waiting for Studio Mac');

  await press(renderer, 'Done');
  expect(allText(renderer)).not.toContain('Waiting for Studio Mac');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('"Try now anyway" sends to the last address instead of queueing', async () => {
  const renderer = await render(
    emptySnapshot({ nearby: [{ ...MAC, remembered: true }] }),
  );
  await press(renderer, 'Studio Mac, Mac, paired, not seen nearby');
  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  await press(renderer, 'Try now anyway');
  expect(native.sendFiles).toHaveBeenCalledWith('abc', FILE_JSON, '{}');
  expect(native.queueFiles).not.toHaveBeenCalled();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a queue that is full explains why instead of pretending', async () => {
  const renderer = await render(
    emptySnapshot({ nearby: [{ ...MAC, remembered: true }] }),
  );
  await press(renderer, 'Studio Mac, Mac, paired, not seen nearby');
  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  native.queueFiles.mockRejectedValueOnce(
    Object.assign(new Error('full'), { code: 'queue_full' }),
  );
  await press(renderer, 'Send when nearby');
  expect(allText(renderer)).toContain('The waiting list is full');
  expect(allText(renderer)).not.toContain('Waiting for Studio Mac');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('the auto-delete toggle in the send tray asks for deletion after 24 h', async () => {
  const renderer = await render(emptySnapshot({ nearby: [MAC] }));
  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  await press(renderer, 'Choose files');
  expect(allText(renderer)).toContain('Auto-delete after 24 h');

  const toggle = renderer.root.find(
    node =>
      node.props.accessibilityLabel === 'Auto-delete after 24 hours' &&
      node.props.accessibilityRole === 'switch',
  );
  expect(toggle.props.accessibilityState.checked).toBe(false);
  await ReactTestRenderer.act(async () => toggle.props.onPress());

  await press(renderer, 'Studio Mac, Mac, paired');
  expect(native.sendFiles).toHaveBeenCalledWith(
    'abc',
    FILE_JSON,
    '{"expiresAfter":86400}',
  );
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows when a received drop deletes itself, in history', async () => {
  const entry: HistoryEntry = {
    id: 'h1',
    direction: 'incoming',
    peerName: 'Studio Mac',
    peerPlatform: 'macos',
    status: 'completed',
    files: [{ name: 'Brief.pdf', size: 1000, uri: 'content://m/1' }],
    totalBytes: 1000,
    finishedAt: Date.now() - 60_000,
    errorCode: null,
    peerId: 'abc',
    kind: 'files',
    link: null,
    canSendAgain: false,
    deleteAt: Date.now() + 23.5 * 3600_000,
    deleted: false,
  };
  const renderer = await render(emptySnapshot({ history: [entry] }));
  await openTab(renderer, 'Activity');
  expect(allText(renderer)).toContain('Deletes in 23 h');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('the clipboard pill copies text from the Mac', async () => {
  const renderer = await render(
    emptySnapshot({
      clip: {
        transferId: 'c1',
        from: 'Studio Mac',
        fromPlatform: 'macos',
        preview: 'Meeting notes for Friday',
        length: 24,
        expiresAt: Date.now() + 120_000,
      },
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Paste from Studio Mac');
  expect(text).toContain('Meeting notes for Friday');
  await press(renderer, 'Copy text from Studio Mac');
  expect(native.copyClip).toHaveBeenCalled();
  expect(allText(renderer)).toContain('Copied');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('the clipboard pill can be dismissed', async () => {
  const renderer = await render(
    emptySnapshot({
      clip: {
        transferId: 'c1',
        from: 'Studio Mac',
        fromPlatform: 'macos',
        preview: 'hello',
        length: 5,
        expiresAt: Date.now() + 120_000,
      },
    }),
  );
  await press(renderer, 'Dismiss');
  expect(native.dismissClip).toHaveBeenCalled();
  expect(allText(renderer)).not.toContain('Paste from Studio Mac');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('an expired clip is not offered', async () => {
  const renderer = await render(
    emptySnapshot({
      clip: {
        transferId: 'c1',
        from: 'Studio Mac',
        fromPlatform: 'macos',
        preview: 'old',
        length: 3,
        expiresAt: Date.now() - 1000,
      },
    }),
  );
  expect(allText(renderer)).not.toContain('Paste from Studio Mac');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

const POCKET: PocketItem[] = [
  {
    id: 'p1',
    uri: 'content://media/1',
    name: 'Report.pdf',
    size: 1_200_000,
    mime: 'application/pdf',
    receivedAt: Date.now() - 120_000,
    from: 'Studio Mac',
    fromPlatform: 'macos',
    deleteAt: null,
  },
  {
    id: 'p2',
    uri: 'content://media/2',
    name: 'Photo.jpg',
    size: 800_000,
    mime: 'image/jpeg',
    receivedAt: Date.now() - 600_000,
    from: 'Studio Mac',
    fromPlatform: 'macos',
    deleteAt: Date.now() + 5 * 3600_000 + 30_000,
  },
];

test('Pocket opens, shares and removes received files', async () => {
  const alert = spyAlert();
  const renderer = await render(emptySnapshot({ pocket: POCKET }));
  await openTab(renderer, 'Activity');
  const text = allText(renderer);
  expect(text).toContain('Pocket');
  expect(text).toContain('Report.pdf');
  expect(text).toContain('Deletes in 5 h');

  const open = renderer.root.find(
    node =>
      String(node.props.accessibilityLabel ?? '').startsWith('Report.pdf.') &&
      typeof node.props.onPress === 'function',
  );
  await ReactTestRenderer.act(async () => open.props.onPress());
  expect(native.openPocketItem).toHaveBeenCalledWith('p1');

  await press(renderer, 'Share Report.pdf');
  expect(native.sharePocketItem).toHaveBeenCalledWith('p1');

  await press(renderer, 'Remove Report.pdf');
  expect(alert.calls[alert.calls.length - 1].title).toBe('Remove Report.pdf?');
  await alert.choose('Remove from Pocket');
  expect(native.removePocketItem).toHaveBeenCalledWith('p1', false);

  await press(renderer, 'Remove Photo.jpg');
  native.removePocketItem.mockResolvedValueOnce(false);
  await alert.choose('Delete file');
  expect(native.removePocketItem).toHaveBeenCalledWith('p2', true);
  expect(alert.calls[alert.calls.length - 1].title).toBe(
    'Couldn’t delete the file',
  );
  alert.restore();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('queued sends show their status with retry and cancel', async () => {
  const item = (overrides: Partial<QueuedSend>): QueuedSend => ({
    id: 'q1',
    deviceId: 'abc',
    deviceName: 'Studio Mac',
    devicePlatform: 'macos',
    paired: true,
    kind: 'files',
    files: [{ name: 'Slides.key', size: 5_000_000, mime: null, copied: true }],
    preview: null,
    totalBytes: 5_000_000,
    createdAt: Date.now() - 60_000,
    status: 'waiting',
    error: null,
    attempts: 0,
    transferId: null,
    expiresAfter: null,
    ...overrides,
  });
  const renderer = await render(
    emptySnapshot({
      queue: [
        item({}),
        item({
          id: 'q2',
          files: [{ name: 'Draft.txt', size: 10, mime: null, copied: false }],
          status: 'failed',
          error: 'rejected',
          attempts: 1,
        }),
      ],
    }),
  );
  await openTab(renderer, 'Activity');
  const text = allText(renderer);
  expect(text).toContain('Waiting to send');
  expect(text).toContain('Goes when Studio Mac is nearby');
  expect(text).toContain('The other device didn’t accept it.');

  await press(renderer, 'Retry sending Draft.txt to Studio Mac');
  expect(native.retryQueued).toHaveBeenCalledWith('q2');
  await press(renderer, 'Cancel sending Slides.key to Studio Mac');
  expect(native.cancelQueued).toHaveBeenCalledWith('q1');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('starts a Drip Room and shows its code, members and End', async () => {
  const alert = spyAlert();
  const renderer = await render(emptySnapshot());
  await openTab(renderer, 'Devices');
  await press(renderer, 'Start a room');
  expect(allText(renderer)).toContain('Start a Drip Room');

  const name = renderer.root.find(
    node =>
      node.props.accessibilityLabel === 'Room name' &&
      typeof node.props.onChangeText === 'function',
  );
  await ReactTestRenderer.act(async () =>
    name.props.onChangeText('Design review'),
  );
  await press(renderer, 'Ends after 2 h');
  await press(renderer, 'Start room');
  expect(native.startRoom).toHaveBeenCalledWith('Design review', 120);

  // The engine reports the room it now hosts.
  await emit(
    renderer,
    emptySnapshot({
      receiving: {
        enabled: true,
        mode: 'mine',
        base: 'off',
        port: 4100,
        error: null,
        autoOffAt: null,
      },
      room: {
        id: 'r1',
        name: 'Design review',
        expiresAt: Date.now() + 120 * 60_000,
        hosting: true,
        invite: 'crossdrop://room?v=1&id=AAECAwQFBgcICQoLDA0ODw',
        members: 0,
      },
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Design review');
  expect(text).toContain('No one nearby yet');
  expect(native.roomQrPng).toHaveBeenCalled();
  const qr = renderer.root.findAll(
    node =>
      typeof node.props.source === 'object' &&
      node.props.source !== null &&
      String(node.props.source.uri ?? '').startsWith('data:image/png;base64,'),
  );
  expect(qr.length).toBeGreaterThan(0);

  await press(renderer, 'End room');
  expect(alert.calls[alert.calls.length - 1].title).toBe('End Design review?');
  await alert.choose('End room');
  expect(native.leaveRoom).toHaveBeenCalled();
  alert.restore();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a room that can’t start says why', async () => {
  const renderer = await render(emptySnapshot());
  await openTab(renderer, 'Devices');
  await press(renderer, 'Start a room');
  native.startRoom.mockRejectedValueOnce(
    Object.assign(new Error('no_network'), { code: 'no_network' }),
  );
  await press(renderer, 'Start room');
  expect(allText(renderer)).toContain('Connect to Wi‑Fi first');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('joins a Drip Room by scanning its code', async () => {
  const alert = spyAlert();
  native.scanPairingCode.mockResolvedValueOnce(
    'crossdrop://room?v=1&id=AAECAwQFBgcICQoLDA0ODw',
  );
  const renderer = await render(emptySnapshot());
  await openTab(renderer, 'Devices');
  await press(renderer, 'Join by scanning');
  expect(native.joinRoom).toHaveBeenCalledWith(
    'crossdrop://room?v=1&id=AAECAwQFBgcICQoLDA0ODw',
  );
  expect(native.pairWithCode).not.toHaveBeenCalled();
  expect(alert.calls[alert.calls.length - 1].title).toBe(
    'You’re in Design review',
  );
  alert.restore();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows the active room and marks room members nearby', async () => {
  const renderer = await render(
    emptySnapshot({
      nearby: [{ ...MAC, trusted: false, inRoom: true }],
      room: {
        id: 'r1',
        name: 'Design review',
        expiresAt: Date.now() + 42 * 60_000 + 30_000,
        hosting: false,
        invite: null,
        members: 1,
      },
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Drip Room · Design review');
  expect(text).toContain('1 nearby in the room · 42 min left');
  expect(text).toContain('In your room');
  expect(
    pressable(renderer, 'Studio Mac, Mac, new device, in your Drip Room'),
  ).toBeTruthy();

  await press(
    renderer,
    'Drip Room Design review. 1 nearby in the room · 42 min left',
  );
  expect(allText(renderer)).toContain('Leave room');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a photo request from the Mac opens the capture stage', async () => {
  const renderer = await render(
    emptySnapshot({
      captureRequests: [
        {
          requestId: 'r1',
          peerId: 'abc',
          peerName: 'Studio Mac',
          kind: 'photo',
          expiresAt: Date.now() + 120_000,
          state: 'open',
        },
      ],
      captureFocus: 'r1',
    }),
  );
  expect(allText(renderer)).toContain('Studio Mac wants a photo');
  expect(native.clearCaptureFocus).toHaveBeenCalled();
  await press(renderer, 'Take photo');
  expect(native.startCapture).toHaveBeenCalledWith('r1', 'photo');
  await press(renderer, 'Pick photo');
  expect(native.startCapture).toHaveBeenCalledWith('r1', 'pick');
  await press(renderer, 'Not now');
  expect(native.declineCapture).toHaveBeenCalledWith('r1');
  expect(allText(renderer)).not.toContain('Studio Mac wants a photo');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a device tapped on the widget opens the picker and sends to it', async () => {
  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  const renderer = await render(
    emptySnapshot({
      nearby: [MAC],
      pendingTarget: {
        deviceId: 'abc',
        name: 'Studio Mac',
        platform: 'macos',
        at: 1234,
      },
    }),
  );
  expect(native.clearPendingTarget).toHaveBeenCalled();
  expect(native.pickFiles).toHaveBeenCalled();
  expect(native.sendFiles).toHaveBeenCalledWith('abc', FILE_JSON, '{}');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('Settings switches Sort by type and Turbo', async () => {
  const renderer = await render(emptySnapshot());
  await openTab(renderer, 'Settings');
  const text = allText(renderer);
  expect(text).toContain('Sort by type');
  expect(text).toContain('Turbo');
  expect(text).toContain('heartbeat');
  const toggle = (label: string) =>
    renderer.root.find(
      node =>
        node.props.accessibilityLabel === label &&
        node.props.accessibilityRole === 'switch',
    );
  await ReactTestRenderer.act(async () =>
    toggle('Sort by type').props.onPress(),
  );
  expect(native.setPreference).toHaveBeenCalledWith('sortByType', true);
  await ReactTestRenderer.act(async () =>
    toggle('Turbo, experimental').props.onPress(),
  );
  expect(native.setPreference).toHaveBeenCalledWith('turbo', true);
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a send that can’t reach a paired Mac can be queued from the result', async () => {
  const trusted = {
    deviceId: 'abc',
    name: 'Studio Mac',
    platform: 'macos' as const,
    fingerprint: 'f'.repeat(64),
    pairedAt: Date.now() - 86400_000,
    lastUsedAt: null,
    autoAccept: false,
    expiresAt: null,
  };
  const renderer = await render(
    emptySnapshot({ nearby: [MAC], trusted: [trusted] }),
  );
  native.pickFiles.mockResolvedValueOnce(FILE_JSON);
  native.sendFiles.mockResolvedValueOnce('t-77');
  await press(renderer, 'Studio Mac, Mac, paired');
  expect(native.sendFiles).toHaveBeenCalledWith('abc', FILE_JSON, '{}');

  const attempt = {
    id: 't-77',
    direction: 'outgoing' as const,
    peerId: 'abc',
    peerName: 'Studio Mac',
    peerPlatform: 'macos' as const,
    status: 'connecting' as const,
    files: [{ name: 'a.txt', size: 3, mime: null, bytes: 0, uri: null }],
    totalBytes: 3,
    bytesTransferred: 0,
    bytesPerSecond: null,
    startedAt: Date.now(),
    updatedAt: Date.now(),
    error: null,
    rejectReason: null,
    canRetry: false,
    kind: 'files' as const,
    text: null,
    expiresAfter: null,
    deleteAt: null,
    deleted: false,
    streams: 1,
    queueId: null,
    answersCapture: false,
  };
  await emit(
    renderer,
    emptySnapshot({ nearby: [MAC], trusted: [trusted], transfers: [attempt] }),
  );
  await emit(
    renderer,
    emptySnapshot({
      nearby: [MAC],
      trusted: [trusted],
      transfers: [
        {
          ...attempt,
          status: 'failed',
          error: { code: 'unreachable', message: null },
          canRetry: true,
        },
      ],
    }),
  );
  expect(allText(renderer)).toContain('That didn’t go through');
  await press(renderer, 'Send when nearby');
  expect(native.queueFiles).toHaveBeenCalledWith('abc', FILE_JSON, '{}');
  expect(allText(renderer)).toContain('goes by itself once it’s found');
  await ReactTestRenderer.act(async () => renderer.unmount());
});
