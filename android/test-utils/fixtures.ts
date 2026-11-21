import type { Snapshot } from '../src/native/types';

export function emptySnapshot(overrides: Partial<Snapshot> = {}): Snapshot {
  return {
    local: {
      deviceId: '5eb62f5e1e01878da64cab4f2bce97d1',
      name: 'Pixel 8',
      fingerprint:
        '5eb62f5e1e01878da64cab4f2bce97d1a0b1c2d3e4f5061728394a5b6c7d8e9f',
    },
    receiving: {
      enabled: false,
      mode: 'off',
      base: 'off',
      port: null,
      error: null,
      autoOffAt: null,
    },
    discovery: { active: true, error: null },
    network: { localNetwork: true },
    nearby: [],
    newestDeviceAt: 0,
    trusted: [],
    transfers: [],
    pairing: [],
    offers: [],
    history: [],
    shared: [],
    sharedText: null,
    lastDeviceId: null,
    screenshotPermission: false,
    notificationPermission: 'undetermined',
    destinationLabel: 'Download/CrossDrop',
    appVersion: '0.1.0',
    prefs: {
      sound: true,
      haptics: true,
      welcomed: true,
      screenshotOffer: false,
    },
    ...overrides,
  };
}
