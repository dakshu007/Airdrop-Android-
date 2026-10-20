import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  Animated,
  BackHandler,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { isFinal } from '../copy';
import { useAppActive } from '../hooks/useAppActive';
import { useReducedMotion } from '../hooks/useReducedMotion';
import * as CrossDrop from '../native/crossdrop';
import { Overlays } from '../overlays/Overlays';
import { ActivityScreen } from '../screens/ActivityScreen';
import { DevicesScreen } from '../screens/DevicesScreen';
import { nearbyMode, NearbyScreen } from '../screens/NearbyScreen';
import { SettingsScreen } from '../screens/SettingsScreen';
import { ShareScreen } from '../screens/ShareScreen';
import { useSnapshot } from '../state/CrossDropProvider';
import { useDiscovery } from '../state/useDiscovery';
import { Backdrop, Mood } from '../theme/Backdrop';
import { NavigationContext, TabKey } from './NavigationContext';
import { TabBar } from './TabBar';

function ScreenFor({ tab }: { tab: TabKey }) {
  switch (tab) {
    case 'nearby':
      return <NearbyScreen />;
    case 'activity':
      return <ActivityScreen />;
    case 'devices':
      return <DevicesScreen />;
    case 'settings':
      return <SettingsScreen />;
  }
}

/**
 * Small state-based navigator: four tabs with a fade-and-rise transition, a
 * share-sheet layer that slides over them, and the full-screen moments
 * (pairing, incoming files, transfers) on top.
 */
export function Navigator() {
  const snapshot = useSnapshot();
  const reduced = useReducedMotion();
  const appActive = useAppActive();
  const { height } = useWindowDimensions();
  const [tab, setTab] = useState<TabKey>('nearby');
  const enter = useRef(new Animated.Value(1)).current;
  const shareProgress = useRef(new Animated.Value(0)).current;

  const sharing = snapshot.shared.length > 0;
  useDiscovery(appActive && (tab === 'nearby' || sharing));

  const navigate = useCallback((next: TabKey) => setTab(next), []);

  // Start the entrance animation after the new screen has mounted, so the
  // animated node is attached before it runs (required by the native driver).
  const firstTab = useRef(true);
  useEffect(() => {
    if (firstTab.current) {
      firstTab.current = false;
      return;
    }
    if (reduced) {
      enter.setValue(1);
      return;
    }
    enter.setValue(0);
    const anim = Animated.spring(enter, {
      toValue: 1,
      useNativeDriver: true,
      speed: 16,
      bounciness: 3,
    });
    anim.start();
    return () => anim.stop();
  }, [tab, enter, reduced]);

  useEffect(() => {
    const to = sharing ? 1 : 0;
    if (reduced) {
      shareProgress.setValue(to);
    } else {
      Animated.spring(shareProgress, {
        toValue: to,
        useNativeDriver: true,
        speed: 14,
        bounciness: 2,
      }).start();
    }
  }, [sharing, reduced, shareProgress]);

  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (sharing) {
        CrossDrop.clearSharedFiles();
        return true;
      }
      if (tab !== 'nearby') {
        navigate('nearby');
        return true;
      }
      return false;
    });
    return () => sub.remove();
  }, [sharing, tab, navigate]);

  const nav = useMemo(() => ({ tab, navigate }), [tab, navigate]);
  const activeCount =
    snapshot.transfers.filter(tr => !isFinal(tr.status)).length +
    snapshot.offers.length;
  const mood: Mood =
    tab === 'nearby' && nearbyMode(snapshot) === 'napping' ? 'off' : 'idle';

  return (
    <NavigationContext.Provider value={nav}>
      <Backdrop mood={mood} />
      <View
        style={styles.flex}
        importantForAccessibility={sharing ? 'no-hide-descendants' : 'auto'}
      >
        <Animated.View
          key={tab}
          style={[
            styles.flex,
            {
              opacity: enter,
              transform: [
                {
                  translateY: enter.interpolate({
                    inputRange: [0, 1],
                    outputRange: [14, 0],
                  }),
                },
              ],
            },
          ]}
        >
          <ScreenFor tab={tab} />
        </Animated.View>
        <TabBar
          current={tab}
          onSelect={navigate}
          badges={{ activity: activeCount }}
        />
      </View>
      {sharing ? (
        <Animated.View
          style={[
            StyleSheet.absoluteFill,
            {
              opacity: reduced ? 1 : shareProgress,
              transform: [
                {
                  translateY: shareProgress.interpolate({
                    inputRange: [0, 1],
                    outputRange: [height * 0.25, 0],
                  }),
                },
              ],
            },
          ]}
        >
          <Backdrop mood="idle" />
          <ShareScreen />
        </Animated.View>
      ) : null}
      <Overlays />
    </NavigationContext.Provider>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
});
