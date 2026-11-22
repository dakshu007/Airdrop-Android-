import { useEffect, useRef } from 'react';
import * as CrossDrop from '../native/crossdrop';
import type { NearbyDevice } from '../native/types';
import { useNavigation } from '../navigation/NavigationContext';
import { useCrossDrop, useSnapshot } from './CrossDropProvider';
import { useSendFlow } from './useSendFlow';
import { pickFilesSafely } from './useSendFiles';

/**
 * A device tapped on the home-screen widget: go to Nearby and start the send
 * for it — files already chosen, or the picker. A paired device that isn't
 * around yet gets the "Send when nearby" offer. Rendered once by the navigator.
 */
export function WidgetTarget() {
  const snapshot = useSnapshot();
  const { navigate } = useNavigation();
  const { selection, clearSelection } = useCrossDrop();
  const flow = useSendFlow({
    resolveFiles: async () =>
      selection.length > 0 ? selection : pickFilesSafely(),
    count: selection.length,
    text: null,
    onDone: clearSelection,
  });
  const handled = useRef(0);
  const target = snapshot.pendingTarget;
  const { select } = flow;

  useEffect(() => {
    if (!target || target.at === handled.current) return;
    handled.current = target.at;
    CrossDrop.clearPendingTarget();
    navigate('nearby');
    const found = snapshot.nearby.find(d => d.deviceId === target.deviceId);
    const device: NearbyDevice = found ?? {
      deviceId: target.deviceId,
      name: target.name,
      platform: target.platform,
      trusted: true,
      remembered: true,
      inRoom: false,
    };
    select(device);
    // Runs once per widget tap; the nearby list is read at that moment.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target, navigate, select]);

  return flow.element;
}
