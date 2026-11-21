import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import type { ReceiveMode, Snapshot } from '../native/types';
import { useReceiveMode } from '../state/useReceiving';
import { useTheme } from '../theme/ThemeProvider';
import { green, spacing } from '../theme/tokens';
import { Icon, type IconName } from './Icon';
import { Sheet } from './Sheet';
import { Text } from './Text';

const OPTIONS: {
  mode: ReceiveMode;
  title: string;
  detail: string;
  icon: IconName;
}[] = [
  {
    mode: 'mine',
    title: 'My devices',
    detail:
      'Always ready for devices you paired, even when CrossDrop is closed. Invisible to everyone else. Keeps a quiet notification.',
    icon: 'heart',
  },
  {
    mode: 'everyone',
    title: 'Everyone for 10 minutes',
    detail:
      'Anyone nearby can see this phone and ask to send. New devices confirm a code first.',
    icon: 'radar',
  },
  {
    mode: 'off',
    title: 'Off',
    detail: 'Nobody can send to this phone. You can still send.',
    icon: 'x',
  },
];

/** AirDrop-style choice of who can send to this phone. */
export function ReceiveModeSheet({
  snapshot,
  onClose,
}: {
  snapshot: Snapshot;
  onClose: () => void;
}) {
  const t = useTheme();
  const setMode = useReceiveMode(snapshot);
  const current = snapshot.receiving.mode;
  return (
    <Sheet
      visible
      onRequestClose={onClose}
      accessibilityLabel="Who can send to you"
    >
      <Text variant="title" accessibilityRole="header">
        Who can send to you
      </Text>
      <View style={styles.list} accessibilityRole="radiogroup">
        {OPTIONS.map(o => {
          const selected = current === o.mode;
          return (
            <Pressable
              key={o.mode}
              onPress={() => {
                setMode(o.mode);
                onClose();
              }}
              accessibilityRole="radio"
              accessibilityState={{ checked: selected }}
              accessibilityLabel={o.title}
              accessibilityHint={o.detail}
              style={[
                styles.option,
                {
                  backgroundColor: selected ? 'rgba(20,154,91,0.10)' : t.inset,
                },
                selected && styles.optionSelected,
              ]}
            >
              <View
                style={[
                  styles.icon,
                  { backgroundColor: selected ? green : 'rgba(15,29,22,0.08)' },
                ]}
              >
                <Icon
                  name={o.icon}
                  size={20}
                  color={selected ? '#FFFFFF' : t.textPrimary}
                />
              </View>
              <View style={styles.text}>
                <Text variant="headline">{o.title}</Text>
                <Text variant="footnote" tone="secondary">
                  {o.detail}
                </Text>
              </View>
              {selected ? <Icon name="check" size={20} color={green} /> : null}
            </Pressable>
          );
        })}
      </View>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  list: { gap: spacing.sm, marginTop: spacing.sm },
  option: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    borderRadius: 20,
    padding: spacing.md,
    minHeight: 72,
    borderWidth: 1.5,
    borderColor: 'transparent',
  },
  optionSelected: { borderColor: 'rgba(20,154,91,0.55)' },
  icon: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  text: { flex: 1, gap: 2 },
});
