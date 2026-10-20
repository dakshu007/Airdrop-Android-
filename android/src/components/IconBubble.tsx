import React from 'react';
import { StyleSheet, View } from 'react-native';
import { Frost } from './Frost';
import { Icon, IconName } from './Icon';

/** An icon inside a small round glass lens. */
export function IconBubble({
  name,
  size = 44,
  color = '#FFFFFF',
  background,
}: {
  name: IconName;
  size?: number;
  color?: string;
  background?: string;
}) {
  return (
    <View style={[styles.bubble, { width: size, height: size, borderRadius: size / 2 }]}>
      <Frost radius={size / 2} tint={background ?? 'rgba(255,255,255,0.16)'} />
      <Icon name={name} size={Math.round(size * 0.46)} color={color} />
    </View>
  );
}

const styles = StyleSheet.create({
  bubble: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
});
