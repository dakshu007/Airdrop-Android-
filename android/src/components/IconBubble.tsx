import React from 'react';
import { StyleSheet, View } from 'react-native';
import { useTheme } from '../theme/ThemeProvider';
import { Icon, IconName } from './Icon';
import { Specular } from './Specular';

/** An icon inside a small round glass lens. */
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
          borderRadius: size / 2,
          backgroundColor: background ?? t.accentSoft,
          borderColor: t.glassBorder,
        },
      ]}
    >
      <Specular color={t.specular} />
      <Icon
        name={name}
        size={size * 0.5}
        color={color ?? (t.scheme === 'dark' ? '#9DB8FF' : t.accent)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  bubble: {
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    overflow: 'hidden',
  },
});
