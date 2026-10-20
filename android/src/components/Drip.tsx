import React, { useEffect, useRef } from 'react';
import {
  Animated,
  Easing,
  Image,
  ImageSourcePropType,
  StyleSheet,
  View,
} from 'react-native';
import { useStill } from '../hooks/useStill';

/** Drip, the CrossDrop character. Renders from scripts/render_illustrations.py. */
export type Pose =
  | 'welcome'
  | 'nearby'
  | 'pairing'
  | 'incoming'
  | 'sending'
  | 'done'
  | 'sleepy'
  | 'searching'
  | 'nowifi'
  | 'failed';

const POSES: Record<Pose, ImageSourcePropType> = {
  welcome: require('../assets/drip/welcome.png'),
  nearby: require('../assets/drip/nearby.png'),
  pairing: require('../assets/drip/pairing.png'),
  incoming: require('../assets/drip/incoming.png'),
  sending: require('../assets/drip/sending.png'),
  done: require('../assets/drip/done.png'),
  sleepy: require('../assets/drip/sleepy.png'),
  searching: require('../assets/drip/searching.png'),
  nowifi: require('../assets/drip/nowifi.png'),
  failed: require('../assets/drip/failed.png'),
};

/** Same pose with the eyes closed, cross-faded in for a blink. */
const BLINKS: Partial<Record<Pose, ImageSourcePropType>> = {
  welcome: require('../assets/drip/welcome_blink.png'),
  nearby: require('../assets/drip/nearby_blink.png'),
};

/**
 * How Drip moves: 'bob' floats gently, 'float' rides higher and sways (the
 * paper plane), 'breathe' is slow and small (napping), 'scan' sweeps side to
 * side (binoculars), 'wobble' shakes once (something went wrong), 'pop'
 * springs in once (done). All motion stops with Reduce motion.
 */
export type Motion =
  | 'bob'
  | 'float'
  | 'breathe'
  | 'scan'
  | 'wobble'
  | 'pop'
  | 'none';

interface DripProps {
  pose: Pose;
  size: number;
  motion?: Motion;
  /** -1 leans toward the left, 1 toward the right, 0 upright. */
  lean?: number;
  /** Describes the picture for screen readers; omit when the screen text already says it. */
  label?: string;
}

function loop(v: Animated.Value, duration: number) {
  return Animated.loop(
    Animated.sequence([
      Animated.timing(v, {
        toValue: 1,
        duration,
        easing: Easing.inOut(Easing.sin),
        useNativeDriver: true,
      }),
      Animated.timing(v, {
        toValue: 0,
        duration,
        easing: Easing.inOut(Easing.sin),
        useNativeDriver: true,
      }),
    ]),
  );
}

export function Drip({
  pose,
  size,
  motion = 'bob',
  lean = 0,
  label,
}: DripProps) {
  const reduced = useStill();
  const cycle = useRef(new Animated.Value(0)).current;
  const once = useRef(
    new Animated.Value(motion === 'pop' || motion === 'wobble' ? 0 : 1),
  ).current;
  const blink = useRef(new Animated.Value(0)).current;
  const leanV = useRef(new Animated.Value(lean)).current;
  const blinkSource = BLINKS[pose];

  useEffect(() => {
    if (reduced) {
      cycle.setValue(0);
      once.setValue(1);
      return;
    }
    if (motion === 'pop' || motion === 'wobble') {
      once.setValue(0);
      const anim =
        motion === 'pop'
          ? Animated.spring(once, {
              toValue: 1,
              useNativeDriver: true,
              speed: 9,
              bounciness: 12,
            })
          : Animated.timing(once, {
              toValue: 1,
              duration: 1100,
              easing: Easing.out(Easing.quad),
              useNativeDriver: true,
            });
      anim.start();
      return () => anim.stop();
    }
    if (motion === 'none') return;
    const period = { bob: 2100, float: 1200, breathe: 2400, scan: 1600 }[
      motion
    ];
    const anim = loop(cycle, period);
    anim.start();
    return () => anim.stop();
  }, [motion, reduced, cycle, once]);

  useEffect(() => {
    if (!blinkSource || reduced) {
      blink.setValue(0);
      return;
    }
    const anim = Animated.loop(
      Animated.sequence([
        Animated.delay(4200),
        Animated.timing(blink, {
          toValue: 1,
          duration: 60,
          useNativeDriver: true,
        }),
        Animated.delay(110),
        Animated.timing(blink, {
          toValue: 0,
          duration: 80,
          useNativeDriver: true,
        }),
      ]),
    );
    anim.start();
    return () => anim.stop();
  }, [blinkSource, reduced, blink]);

  useEffect(() => {
    if (reduced) {
      leanV.setValue(lean);
      return;
    }
    Animated.spring(leanV, {
      toValue: lean,
      useNativeDriver: true,
      speed: 10,
      bounciness: 10,
    }).start();
  }, [lean, reduced, leanV]);

  type Step = Record<
    string,
    | Animated.AnimatedInterpolation<number>
    | Animated.AnimatedInterpolation<string>
    | number
  >;
  const transforms: Step[] = [];
  if (motion === 'bob') {
    transforms.push({
      translateY: cycle.interpolate({
        inputRange: [0, 1],
        outputRange: [0, -8],
      }),
    });
  } else if (motion === 'float') {
    transforms.push(
      {
        translateY: cycle.interpolate({
          inputRange: [0, 1],
          outputRange: [0, -10],
        }),
      },
      {
        rotate: cycle.interpolate({
          inputRange: [0, 1],
          outputRange: ['-2deg', '2deg'],
        }),
      },
    );
  } else if (motion === 'breathe') {
    transforms.push(
      {
        translateY: cycle.interpolate({
          inputRange: [0, 1],
          outputRange: [0, -3],
        }),
      },
      {
        scale: cycle.interpolate({
          inputRange: [0, 1],
          outputRange: [1, 1.015],
        }),
      },
    );
  } else if (motion === 'scan') {
    transforms.push({
      rotate: cycle.interpolate({
        inputRange: [0, 1],
        outputRange: ['-5deg', '5deg'],
      }),
    });
  } else if (motion === 'pop') {
    transforms.push({
      scale: once.interpolate({ inputRange: [0, 1], outputRange: [0.6, 1] }),
    });
  } else if (motion === 'wobble') {
    transforms.push({
      rotate: once.interpolate({
        inputRange: [0, 0.2, 0.4, 0.6, 0.8, 1],
        outputRange: ['0deg', '-3deg', '2.5deg', '-1.5deg', '0.8deg', '0deg'],
      }),
    });
  }
  // Lean pivots near Drip's feet: shift, rotate, shift back.
  const pivot = size * 0.4;
  transforms.push(
    { translateY: pivot },
    {
      translateX: leanV.interpolate({
        inputRange: [-1, 1],
        outputRange: [-6, 6],
      }),
    },
    {
      rotate: leanV.interpolate({
        inputRange: [-1, 1],
        outputRange: ['-7deg', '7deg'],
      }),
    },
    { translateY: -pivot },
  );

  return (
    <View
      style={{ width: size, height: size }}
      accessible={!!label}
      accessibilityRole={label ? 'image' : undefined}
      accessibilityLabel={label}
      importantForAccessibility={label ? 'yes' : 'no-hide-descendants'}
    >
      <Animated.View
        style={[
          StyleSheet.absoluteFill,
          {
            transform: transforms,
            // Always the animated value for pop (set to 1 when still), never
            // swapped for a constant, which can strand the native view at 0.
            opacity: motion === 'pop' ? once : 1,
          },
        ]}
      >
        <Image
          source={POSES[pose]}
          style={styles.fill}
          resizeMode="contain"
          fadeDuration={0}
        />
        {blinkSource ? (
          <Animated.Image
            source={blinkSource}
            style={[styles.fill, StyleSheet.absoluteFill, { opacity: blink }]}
            resizeMode="contain"
            fadeDuration={0}
          />
        ) : null}
      </Animated.View>
    </View>
  );
}

/**
 * Decodes every pose once, invisibly, so a screen that shows Drip for the
 * first time (pairing, incoming, done) doesn't wait for the image.
 */
export function DripPreloader() {
  const sources = [...Object.values(POSES), ...Object.values(BLINKS)];
  return (
    <View
      pointerEvents="none"
      style={styles.preload}
      importantForAccessibility="no-hide-descendants"
    >
      {sources.map((source, i) => (
        <Image key={i} source={source} style={styles.dot} fadeDuration={0} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { width: '100%', height: '100%' },
  preload: {
    position: 'absolute',
    left: 0,
    top: 0,
    opacity: 0,
    flexDirection: 'row',
  },
  dot: { width: 1, height: 1 },
});
