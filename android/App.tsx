/**
 * CrossDrop for Android — UI root.
 *
 * @format
 */

import React from 'react';
import { ActivityIndicator, StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { Button } from './src/components/Button';
import { GlassCard } from './src/components/GlassCard';
import { IconBubble } from './src/components/IconBubble';
import { Text } from './src/components/Text';
import { Navigator } from './src/navigation/Navigator';
import { CrossDropProvider, useCrossDrop } from './src/state/CrossDropProvider';
import { ThemeProvider, useTheme } from './src/theme/ThemeProvider';
import { spacing } from './src/theme/tokens';
import { WallpaperBackdrop } from './src/theme/Wallpaper';

function Root() {
  const t = useTheme();
  const { snapshot, loadError, reload } = useCrossDrop();

  let content: React.ReactNode;
  if (snapshot) {
    content = <Navigator />;
  } else if (loadError) {
    content = (
      <View style={styles.center}>
        <GlassCard style={styles.card}>
          <View style={styles.cardInner}>
            <IconBubble
              name="alert"
              size={56}
              color={t.danger}
              background={t.dangerSoft}
            />
            <Text variant="title" center>
              CrossDrop couldn’t start
            </Text>
            <Text variant="callout" tone="secondary" center>
              The transfer engine didn’t respond. Try again; if it keeps
              happening, restart the app.
            </Text>
            <Button title="Try again" icon="refresh" onPress={reload} />
          </View>
        </GlassCard>
      </View>
    );
  } else {
    content = (
      <View
        style={styles.center}
        accessible
        accessibilityLabel="Starting CrossDrop"
      >
        <IconBubble name="drop" size={72} />
        <Text variant="title" center>
          CrossDrop
        </Text>
        <ActivityIndicator color={t.textSecondary} />
      </View>
    );
  }

  return (
    <WallpaperBackdrop choice={snapshot?.wallpaper}>
      <StatusBar barStyle="light-content" />
      {content}
    </WallpaperBackdrop>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <ThemeProvider>
        <CrossDropProvider>
          <Root />
        </CrossDropProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.md,
    padding: spacing.xl,
  },
  card: { alignSelf: 'stretch' },
  cardInner: { alignItems: 'center', gap: spacing.md, padding: spacing.sm },
});
