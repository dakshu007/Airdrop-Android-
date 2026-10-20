import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { Icon, IconName } from './Icon';

/** An icon on a soft mint tile. */
export function IconBubble({
  name,
  size = 44,
  color,
  background,
}: {
  name: IconName;
  size?: number;
  color?: string;
  background?: string;
}) {
  const t = useTheme();
  return (
    <View
      style={[
        styles.bubble,
        {
          width: size,
          height: size,
          borderRadius: Math.round(size * 0.32),
          backgroundColor: background ?? '#E3F5E8',
        },
      ]}
    >
      <Icon
        name={name}
        size={Math.round(size * 0.46)}
        color={color ?? t.link}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  bubble: { alignItems: 'center', justifyContent: 'center' },
});
