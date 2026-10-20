import React, { useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Button } from '../components/Button';
import { FloatChip, StatusPill } from '../components/Chips';
import { Drip } from '../components/Drip';
import { Icon, IconName } from '../components/Icon';
import { Text } from '../components/Text';
import * as CrossDrop from '../native/crossdrop';
import { useTheme } from '../theme/ThemeProvider';
import { spacing } from '../theme/tokens';

const CHIPS: {
  icon: IconName;
  label: string;
  side: 'left' | 'right';
  top: number;
  tilt: number;
}[] = [
  { icon: 'lock', label: 'Encrypted', side: 'left', top: 0.72, tilt: -8 },
  { icon: 'wifi', label: 'Same Wi‑Fi', side: 'right', top: 0.02, tilt: 10 },
  { icon: 'cloudOff', label: 'No cloud', side: 'right', top: 0.86, tilt: -6 },
];

/** First launch: who Drip is and the three promises, then into the app. */
export function WelcomeScreen() {
  const t = useTheme();
  const insets = useSafeAreaInsets();
  const [box, setBox] = useState<{ w: number; h: number } | null>(null);
  const size = box ? Math.round(Math.min(box.w * 0.98, box.h * 0.96, 380)) : 0;

  return (
    <ScrollView
      contentContainerStyle={[
        styles.content,
        {
          paddingTop: insets.top + spacing.xl,
          paddingBottom: insets.bottom + spacing.xl,
          paddingLeft: insets.left + spacing.xl,
          paddingRight: insets.right + spacing.xl,
        },
      ]}
      bounces={false}
      showsVerticalScrollIndicator={false}
    >
      <View style={styles.head}>
        <StatusPill label="Private by design" />
        <Text
          variant="display"
          center
          accessibilityRole="header"
          style={styles.title}
        >
          CrossDrop
        </Text>
        <Text variant="body" tone="secondary" center style={styles.lede}>
          Your phone and your Mac, one tap apart.
        </Text>
      </View>

      <View
        style={styles.stage}
        accessible
        accessibilityRole="image"
        accessibilityLabel="Drip, the CrossDrop drop, waving between a phone and a laptop. Encrypted, same Wi‑Fi, no cloud."
        onLayout={e =>
          setBox({
            w: e.nativeEvent.layout.width,
            h: e.nativeEvent.layout.height,
          })
        }
      >
        {box ? (
          <>
            <View
              style={[StyleSheet.absoluteFill, styles.center]}
              pointerEvents="none"
            >
              <View
                style={[styles.halo, { width: size * 0.8, height: size * 0.8 }]}
              />
              <Drip pose="welcome" size={size} motion="bob" />
            </View>
            {CHIPS.map((chip, i) => (
              <FloatChip
                key={chip.label}
                tilt={chip.tilt}
                phase={i}
                style={[
                  styles.chip,
                  chip.side === 'left' ? styles.left : styles.right,
                  { top: box.h * chip.top },
                ]}
              >
                <Icon
                  name={chip.icon}
                  size={16}
                  color={t.link}
                  strokeWidth={2}
                />
                <Text variant="subhead" style={styles.chipText}>
                  {chip.label}
                </Text>
              </FloatChip>
            ))}
          </>
        ) : null}
      </View>

      <View style={styles.actions}>
        <Button
          title="Get started"
          large
          onPress={() => CrossDrop.setPreference('welcomed', true)}
        />
        <Text variant="footnote" tone="secondary" center>
          Install CrossDrop on your Mac too
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  content: { flexGrow: 1, gap: spacing.md },
  head: { alignItems: 'center', gap: spacing.sm },
  title: { marginTop: spacing.xs, fontSize: 42, lineHeight: 48 },
  lede: { fontSize: 17, lineHeight: 25, maxWidth: 280 },
  stage: { flex: 1, minHeight: 260, marginHorizontal: -spacing.sm },
  center: { alignItems: 'center', justifyContent: 'center' },
  halo: {
    position: 'absolute',
    borderRadius: 999,
    borderWidth: 1,
    borderColor: 'rgba(46,158,102,0.18)',
    backgroundColor: 'rgba(190,245,170,0.3)',
  },
  chip: { position: 'absolute' },
  left: { left: 6 },
  right: { right: 6 },
  chipText: { color: '#2B3D33' },
  actions: { gap: spacing.md },
});
