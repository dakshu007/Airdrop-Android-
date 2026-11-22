/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';
import NativeCrossDrop from '../specs/NativeCrossDrop';
import type { Snapshot, Transfer } from '../src/native/types';
import { emptySnapshot } from '../test-utils/fixtures';

const native = NativeCrossDrop as jest.Mocked<typeof NativeCrossDrop>;
// The copy uses a non-breaking hyphen so "Wi‑Fi" never wraps.
const WIFI = 'Wi‑Fi';

async function render(snapshot: Snapshot) {
  native.getSnapshot.mockResolvedValue(JSON.stringify(snapshot));
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  // The test renderer never lays out; give every measured box a phone-sized frame.
  await ReactTestRenderer.act(async () => {
    renderer!.root
      .findAll(node => typeof node.props.onLayout === 'function')
      .forEach(node =>
        node.props.onLayout({
          nativeEvent: { layout: { x: 0, y: 0, width: 390, height: 420 } },
        }),
      );
  });
  return renderer!;
}

function allText(renderer: ReactTestRenderer.ReactTestRenderer): string {
  return renderer.root
    .findAll(node => (node.type as unknown) === 'Text')
    .map(node => {
      const children = node.props.children;
      return Array.isArray(children) ? children.join('') : String(children);
    })
    .join('\n');
}

function pressable(
  renderer: ReactTestRenderer.ReactTestRenderer,
  label: string,
) {
  return renderer.root.find(
    node =>
      node.props.accessibilityLabel === label &&
      typeof node.props.onPress === 'function',
  );
}

function transfer(overrides: Partial<Transfer> = {}): Transfer {
  return {
    id: 't1',
    direction: 'outgoing',
    peerId: 'abc',
    peerName: 'Studio Mac',
    peerPlatform: 'macos',
    status: 'transferring',
    files: [
      {
        name: 'Holiday.mp4',
        size: 4_000_000,
        mime: 'video/mp4',
        bytes: 2_000_000,
        uri: null,
      },
    ],
    totalBytes: 4_000_000,
    bytesTransferred: 2_000_000,
    bytesPerSecond: 1_000_000,
    startedAt: Date.now() - 5000,
    updatedAt: Date.now(),
    error: null,
    rejectReason: null,
    canRetry: false,
    kind: 'files',
    text: null,
    expiresAfter: null,
    deleteAt: null,
    deleted: false,
    streams: 1,
    queueId: null,
    answersCapture: false,
    ...overrides,
  };
}

afterEach(() => {
  jest.clearAllMocks();
});

test('welcomes a first-time user and remembers it', async () => {
  const renderer = await render(
    emptySnapshot({
      prefs: {
        sound: true,
        haptics: true,
        welcomed: false,
        screenshotOffer: false,
        sortByType: false,
        turbo: false,
      },
    }),
  );
  expect(allText(renderer)).toContain(
    'Your phone and your Mac, one tap apart.',
  );
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Get started').props.onPress(),
  );
  expect(native.setPreference).toHaveBeenCalledWith('welcomed', true);
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('looks for devices while receiving is on, and stops when it leaves', async () => {
  const renderer = await render(
    emptySnapshot({
      receiving: {
        enabled: true,
        mode: 'everyone',
        base: 'off',
        port: 4100,
        error: null,
        autoOffAt: null,
      },
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('CrossDrop');
  expect(text).toContain('No devices yet');
  expect(text).toContain('Drip is still looking.');
  expect(native.startDiscovery).toHaveBeenCalled();
  await ReactTestRenderer.act(async () => renderer.unmount());
  expect(native.stopDiscovery).toHaveBeenCalled();
});

test('Drip naps while receiving is off and nothing is nearby', async () => {
  const renderer = await render(emptySnapshot());
  expect(allText(renderer)).toContain('Drip is napping');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Turn on Receiving').props.onPress(),
  );
  // Notifications are explained first; the alert is mocked by React Native's preset.
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('explains a missing Wi-Fi connection with a way to fix it', async () => {
  const renderer = await render(
    emptySnapshot({ network: { localNetwork: false } }),
  );
  expect(allText(renderer)).toContain(`No ${WIFI}`);
  await ReactTestRenderer.act(async () =>
    pressable(renderer, `Open ${WIFI} settings`).props.onPress(),
  );
  expect(native.openWifiSettings).toHaveBeenCalled();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows a nearby Mac as a chip with its trust state', async () => {
  const renderer = await render(
    emptySnapshot({
      nearby: [
        {
          deviceId: 'abc',
          name: 'Studio Mac',
          platform: 'macos',
          trusted: true,
          remembered: false,
          inRoom: false,
        },
      ],
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Ready to send');
  expect(text).toContain('Studio Mac');
  expect(text).toContain('Paired');
  expect(pressable(renderer, 'Studio Mac, Mac, paired')).toBeTruthy();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows the pairing code as tiles and answers the prompt', async () => {
  const renderer = await render(
    emptySnapshot({
      pairing: [
        {
          sessionId: 's1',
          peerId: 'abc',
          peerName: 'Studio Mac',
          peerPlatform: 'macos',
          code: '309997',
          role: 'sender',
          waitingForPeer: false,
          expiresAt: Date.now() + 120000,
        },
      ],
    }),
  );
  expect(allText(renderer)).toContain('Do these match?');
  const code = renderer.root.find(node =>
    String(node.props.accessibilityLabel ?? '').startsWith(
      'Pairing code 3 0 9, 9 9 7',
    ),
  );
  expect(code).toBeTruthy();
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Codes match').props.onPress(),
  );
  expect(native.respondToPairing).toHaveBeenCalledWith('s1', true, false);
  expect(native.feedback).toHaveBeenCalledWith('confirm');
  expect(allText(renderer)).toContain('Waiting for Studio Mac to confirm…');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows an incoming offer with total size and accepts it', async () => {
  const renderer = await render(
    emptySnapshot({
      offers: [
        {
          transferId: 't9',
          peerId: 'abc',
          peerName: 'Studio Mac',
          peerPlatform: 'macos',
          files: [
            { name: 'Report.pdf', size: 1_200_000, mime: 'application/pdf' },
            { name: 'Photo.jpg', size: 800_000, mime: 'image/jpeg' },
          ],
          totalBytes: 2_000_000,
          expiresAt: Date.now() + 60000,
          kind: 'files',
          expiresAfter: null,
          answersCapture: false,
        },
      ],
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Files are on their way');
  expect(text).toContain('wants to send 2 files · 2 MB');
  expect(text).toContain('Not paired');
  expect(text).toContain('Report.pdf');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Accept').props.onPress(),
  );
  expect(native.respondToOffer).toHaveBeenCalledWith('t9', true);
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('follows a running transfer with progress and cancel', async () => {
  const renderer = await render(emptySnapshot({ transfers: [transfer()] }));
  const text = allText(renderer);
  expect(text).toContain('Sending to Studio Mac');
  expect(text).toContain('50%');
  expect(text).toContain('Connected · encrypted');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Cancel sending Holiday.mp4').props.onPress(),
  );
  expect(native.cancelTransfer).toHaveBeenCalledWith('t1');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows a failed transfer with a retry', async () => {
  const renderer = await render(
    emptySnapshot({
      transfers: [
        transfer({
          status: 'connecting',
        }),
      ],
    }),
  );
  // The transfer fails while it is on screen.
  native.getSnapshot.mockResolvedValue('{}');
  const failed = emptySnapshot({
    transfers: [
      transfer({
        status: 'failed',
        error: { code: 'connection_lost', message: null },
        canRetry: true,
      }),
    ],
  });
  const { DeviceEventEmitter } = require('react-native');
  await ReactTestRenderer.act(async () => {
    DeviceEventEmitter.emit('CrossDropState', { json: JSON.stringify(failed) });
  });
  const text = allText(renderer);
  expect(text).toContain('That didn’t go through');
  expect(text).toContain('Connection lost');
  expect(native.feedback).toHaveBeenCalledWith('error');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Try again').props.onPress(),
  );
  expect(native.retryTransfer).toHaveBeenCalledWith('t1');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows a recoverable error when the engine does not respond', async () => {
  native.getSnapshot.mockRejectedValue(new Error('boom'));
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
  });
  expect(allText(renderer!)).toContain('CrossDrop couldn’t start');
  await ReactTestRenderer.act(async () => renderer!.unmount());
});

/** The share sheet flow sits on top of the Nearby tab, which renders the same chips. */
function topPressable(
  renderer: ReactTestRenderer.ReactTestRenderer,
  label: string,
) {
  const all = renderer.root.findAll(
    node =>
      node.props.accessibilityLabel === label &&
      typeof node.props.onPress === 'function',
  );
  return all[all.length - 1];
}

const MAC = {
  deviceId: 'abc',
  name: 'Studio Mac',
  platform: 'macos' as const,
  trusted: true,
  remembered: false,
  inRoom: false,
};

test('"This is my device" goes along with the pairing answer', async () => {
  const renderer = await render(
    emptySnapshot({
      pairing: [
        {
          sessionId: 's2',
          peerId: 'abc',
          peerName: 'Studio Mac',
          peerPlatform: 'macos',
          code: '123456',
          role: 'receiver',
          waitingForPeer: false,
          expiresAt: Date.now() + 120000,
        },
      ],
    }),
  );
  const toggle = renderer.root.find(
    node =>
      node.props.accessibilityLabel === 'This is my device' &&
      node.props.accessibilityRole === 'switch',
  );
  await ReactTestRenderer.act(async () => toggle.props.onPress());
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Codes match').props.onPress(),
  );
  expect(native.respondToPairing).toHaveBeenCalledWith('s2', true, true);
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('chooses who can send from the receiving pill', async () => {
  const renderer = await render(
    emptySnapshot({ notificationPermission: 'granted' }),
  );
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Receiving: Receiving off').props.onPress(),
  );
  expect(allText(renderer)).toContain('Who can send to you');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'My devices').props.onPress(),
  );
  expect(native.setReceiveMode).toHaveBeenCalledWith('mine');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a shared link is sent as a link, not a file', async () => {
  const renderer = await render(
    emptySnapshot({
      nearby: [MAC],
      sharedText: {
        kind: 'link',
        preview: 'https://example.com/recipe',
        length: 26,
      },
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Send this link');
  expect(text).toContain('https://example.com/recipe');
  await ReactTestRenderer.act(async () =>
    topPressable(renderer, 'Studio Mac, Mac, paired').props.onPress(),
  );
  expect(native.sendSharedText).toHaveBeenCalledWith('abc');
  expect(native.clearSharedFiles).toHaveBeenCalled();
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('a received link waits for the user to open or copy it', async () => {
  const renderer = await render(
    emptySnapshot({
      transfers: [
        transfer({ id: 'L1', direction: 'incoming', status: 'connecting' }),
      ],
    }),
  );
  const done = emptySnapshot({
    transfers: [
      transfer({
        id: 'L1',
        direction: 'incoming',
        status: 'completed',
        kind: 'link',
        text: 'https://example.com/a',
        files: [{ name: 'Link', size: 21, mime: null, bytes: 21, uri: null }],
      }),
    ],
  });
  const { DeviceEventEmitter } = require('react-native');
  await ReactTestRenderer.act(async () => {
    DeviceEventEmitter.emit('CrossDropState', { json: JSON.stringify(done) });
  });
  expect(allText(renderer)).toContain('Link from Studio Mac');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Open link').props.onPress(),
  );
  expect(native.openLink).toHaveBeenCalledWith('https://example.com/a');
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Copy').props.onPress(),
  );
  expect(native.copyText).toHaveBeenCalledWith('https://example.com/a');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('sends to several devices at once', async () => {
  const renderer = await render(
    emptySnapshot({
      nearby: [MAC, { ...MAC, deviceId: 'def', name: 'Office Mac' }],
      shared: [{ uri: 'content://x/1', name: 'a.txt', size: 3, mime: null }],
    }),
  );
  await ReactTestRenderer.act(async () =>
    topPressable(renderer, 'Send to several').props.onPress(),
  );
  for (const name of ['Studio Mac', 'Office Mac']) {
    const boxes = renderer.root.findAll(
      node =>
        node.props.accessibilityRole === 'checkbox' &&
        node.props.accessibilityLabel === name &&
        typeof node.props.onPress === 'function',
    );
    const box = boxes[boxes.length - 1];
    await ReactTestRenderer.act(async () => box.props.onPress());
  }
  await ReactTestRenderer.act(async () =>
    pressable(renderer, 'Send to 2 devices').props.onPress(),
  );
  expect(native.sendFiles).toHaveBeenCalledTimes(2);
  expect(native.sendFiles).toHaveBeenCalledWith(
    'abc',
    expect.any(String),
    '{}',
  );
  expect(native.sendFiles).toHaveBeenCalledWith(
    'def',
    expect.any(String),
    '{}',
  );
  await ReactTestRenderer.act(async () => renderer.unmount());
});
