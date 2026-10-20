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
  Easing,
  StyleSheet,
  useWindowDimensions,
  View,
} from 'react-native';
import { isFinal } from '../copy';
import { useAppActive } from '../hooks/useAppActive';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { ScreenVisibleContext } from '../hooks/useStill';
import * as CrossDrop from '../native/crossdrop';
import { NotificationPrompt } from '../overlays/NotificationPrompt';
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

const TAB_ORDER: TabKey[] = ['nearby', 'activity', 'devices', 'settings'];

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
 * One tab's screen. Screens stay mounted once built, so switching tabs never
 * shows an empty frame or waits for images to decode; the switch is a short
 * cross-fade with a small rise, run on the native thread.
 */
function TabLayer({
  tab,
  active,
  reduced,
}: {
  tab: TabKey;
  active: boolean;
  reduced: boolean;
}) {
  const v = useRef(new Animated.Value(active ? 1 : 0)).current;
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    const anim = reduced
      ? Animated.timing(v, {
          toValue: active ? 1 : 0,
          duration: 120,
          useNativeDriver: true,
        })
      : active
      ? Animated.spring(v, {
          toValue: 1,
          useNativeDriver: true,
          speed: 18,
          bounciness: 2,
        })
      : Animated.timing(v, {
          toValue: 0,
          duration: 140,
          easing: Easing.out(Easing.quad),
          useNativeDriver: true,
        });
    anim.start();
    return () => anim.stop();
  }, [active, reduced, v]);

  return (
    <Animated.View
      pointerEvents={active ? 'box-none' : 'none'}
      importantForAccessibility={active ? 'auto' : 'no-hide-descendants'}
      style={[
        StyleSheet.absoluteFill,
        {
          opacity: v,
          transform: [
            {
              translateY: v.interpolate({
                inputRange: [0, 1],
                outputRange: [reduced ? 0 : 10, 0],
              }),
            },
          ],
        },
      ]}
    >
      <ScreenVisibleContext.Provider value={active}>
        <ScreenFor tab={tab} />
      </ScreenVisibleContext.Provider>
    </Animated.View>
  );
}

/**
 * Small state-based navigator: four tabs that stay mounted and cross-fade, a
 * share-sheet layer that slides over them, and the full-screen moments
 * (pairing, incoming files, transfers) on top.
 */
export function Navigator() {
  const snapshot = useSnapshot();
  const reduced = useReducedMotion();
  const appActive = useAppActive();
  const { height } = useWindowDimensions();
  const [tab, setTab] = useState<TabKey>('nearby');
  // Tabs are built on first visit, and all of them shortly after launch once
  // the first screen is up, so later switches are instant.
  const [built, setBuilt] = useState<Set<TabKey>>(() => new Set(['nearby']));
  const shareProgress = useRef(new Animated.Value(0)).current;

  const sharing = snapshot.shared.length > 0;
  useDiscovery(appActive && (tab === 'nearby' || sharing));

  const navigate = useCallback((next: TabKey) => {
    setBuilt(prev => (prev.has(next) ? prev : new Set(prev).add(next)));
    setTab(next);
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => setBuilt(new Set(TAB_ORDER)), 900);
    return () => clearTimeout(timer);
  }, []);

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
        {TAB_ORDER.filter(key => built.has(key)).map(key => (
          <TabLayer
            key={key}
            tab={key}
            active={key === tab}
            reduced={reduced}
          />
        ))}
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
              opacity: shareProgress,
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
      <NotificationPrompt />
    </NavigationContext.Provider>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
});
