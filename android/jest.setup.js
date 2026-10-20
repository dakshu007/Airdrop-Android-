/* eslint-env jest */

jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);

// react-native-svg ships untranspiled native bindings; render its elements as plain views.
jest.mock('react-native-svg', () => {
  const React = require('react');
  const { View } = require('react-native');
  const Stub = ({ children }) => React.createElement(View, null, children);
  return {
    __esModule: true,
    default: Stub,
    Svg: Stub,
    Circle: Stub,
    Defs: Stub,
    LinearGradient: Stub,
    Path: Stub,
    RadialGradient: Stub,
    Rect: Stub,
    Stop: Stub,
  };
});

// The Kotlin engine is not available under Jest. Tests set getSnapshot's result.
jest.mock('./specs/NativeCrossDrop', () => ({
  __esModule: true,
  default: {
    getSnapshot: jest.fn(),
    startDiscovery: jest.fn(),
    stopDiscovery: jest.fn(),
    setReceiving: jest.fn(),
    pickFiles: jest.fn(() => Promise.resolve('[]')),
    sendFiles: jest.fn(() => Promise.resolve('t-1')),
    respondToPairing: jest.fn(),
    respondToOffer: jest.fn(),
    cancelTransfer: jest.fn(),
    dismissTransfer: jest.fn(),
    retryTransfer: jest.fn(() => Promise.resolve('t-2')),
    forgetDevice: jest.fn(),
    setAutoAccept: jest.fn(),
    setDeviceName: jest.fn(),
    clearSharedFiles: jest.fn(),
    clearHistory: jest.fn(),
    openFile: jest.fn(),
    openDownloads: jest.fn(),
    requestNotificationPermission: jest.fn(() => Promise.resolve('granted')),
    openAppSettings: jest.fn(),
    openWifiSettings: jest.fn(),
    setPreference: jest.fn(),
    feedback: jest.fn(),
  },
}));

// Run with Reduce motion on: every animation takes its static path, so tests
// don't depend on looping native-driver animations the test renderer can't drive.
const { AccessibilityInfo } = require('react-native');
jest
  .spyOn(AccessibilityInfo, 'isReduceMotionEnabled')
  .mockImplementation(() => Promise.resolve(true));
