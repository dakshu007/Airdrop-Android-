/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';
import NativeCrossDrop from '../specs/NativeCrossDrop';
import type { Snapshot } from '../src/native/types';
import { emptySnapshot } from '../test-utils/fixtures';

const native = NativeCrossDrop as jest.Mocked<typeof NativeCrossDrop>;

async function render(snapshot: Snapshot) {
  native.getSnapshot.mockResolvedValue(JSON.stringify(snapshot));
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await ReactTestRenderer.act(async () => {
    renderer = ReactTestRenderer.create(<App />);
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

afterEach(() => {
  jest.clearAllMocks();
});

test('renders the Nearby screen with an empty, scanning state', async () => {
  const renderer = await render(emptySnapshot());
  const text = allText(renderer);
  expect(text).toContain('CrossDrop');
  expect(text).toContain('Looking for nearby devices…');
  expect(text).toContain('No devices yet');
  expect(native.startDiscovery).toHaveBeenCalled();
  await ReactTestRenderer.act(async () => renderer.unmount());
  expect(native.stopDiscovery).toHaveBeenCalled();
});

test('explains a missing Wi-Fi connection', async () => {
  const renderer = await render(
    emptySnapshot({ network: { localNetwork: false } }),
  );
  expect(allText(renderer)).toContain('No Wi-Fi connection');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows a nearby Mac with its trust state', async () => {
  const renderer = await render(
    emptySnapshot({
      nearby: [
        {
          deviceId: 'abc',
          name: 'Studio Mac',
          platform: 'macos',
          trusted: true,
        },
      ],
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Studio Mac');
  expect(text).toContain('Paired');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows the pairing code grouped and answers the prompt', async () => {
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
  expect(allText(renderer)).toContain('309 997');
  const match = renderer.root.find(
    node =>
      node.props.accessibilityLabel === 'Codes match' &&
      typeof node.props.onPress === 'function',
  );
  await ReactTestRenderer.act(async () => match.props.onPress());
  expect(native.respondToPairing).toHaveBeenCalledWith('s1', true);
  expect(allText(renderer)).toContain('Waiting for Studio Mac to confirm…');
  await ReactTestRenderer.act(async () => renderer.unmount());
});

test('shows an incoming offer with total size', async () => {
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
        },
      ],
    }),
  );
  const text = allText(renderer);
  expect(text).toContain('Studio Mac wants to send 2 files');
  expect(text).toContain('Total 2 MB');
  expect(text).toContain('Not paired');
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
