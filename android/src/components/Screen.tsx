import React, { useMemo, useRef } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ScrollOffsetContext } from '../theme/ScrollOffset';
import { spacing } from '../theme/tokens';
import { Text } from './Text';

/** Space reserved at the bottom of scrolling screens for the floating tab bar. */
export const TAB_BAR_SPACE = 104;

interface ScreenProps {
  title: string;
  subtitle?: string;
  trailing?: React.ReactNode;
  children: React.ReactNode;
  bottomSpace?: number;
}

export function Screen({
  title,
  subtitle,
  trailing,
  children,
  bottomSpace = TAB_BAR_SPACE,
}: ScreenProps) {
  const insets = useSafeAreaInsets();
  const y = useRef(new Animated.Value(0)).current;
  const offset = useMemo(() => ({ y, current: { value: 0 } }), [y]);
  const onScroll = useMemo(
    () =>
      Animated.event([{ nativeEvent: { contentOffset: { y } } }], {
        useNativeDriver: true,
        listener: (e: { nativeEvent: { contentOffset: { y: number } } }) => {
          offset.current.value = e.nativeEvent.contentOffset.y;
        },
      }),
    [y, offset],
  );
  return (
    <ScrollOffsetContext.Provider value={offset}>
    <Animated.ScrollView
      style={styles.flex}
      onScroll={onScroll}
      scrollEventThrottle={16}
      showsVerticalScrollIndicator={false}
      contentContainerStyle={{
        paddingTop: insets.top + spacing.lg,
        paddingBottom: insets.bottom + bottomSpace,
        paddingLeft: insets.left + spacing.lg,
        paddingRight: insets.right + spacing.lg,
      }}
      keyboardShouldPersistTaps="handled"
    >
      <View style={styles.header}>
        <View style={styles.flex}>
          <Text variant="largeTitle" accessibilityRole="header">
            {title}
          </Text>
          {subtitle ? (
            <Text variant="callout" tone="secondary">
              {subtitle}
            </Text>
          ) : null}
        </View>
        {trailing}
      </View>
      {children}
    </Animated.ScrollView>
    </ScrollOffsetContext.Provider>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  header: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.sm,
    marginBottom: spacing.lg,
  },
});
