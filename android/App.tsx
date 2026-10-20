/**
 * CrossDrop for Android — UI root.
 *
 * @format
 */

import React from 'react';
import { ActivityIndicator, StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { Button } from './src/components/Button';
import { Drip } from './src/components/Drip';
import { Logo } from './src/components/Logo';
import { Text } from './src/components/Text';
import { Navigator } from './src/navigation/Navigator';
import { WelcomeScreen } from './src/screens/WelcomeScreen';
import { CrossDropProvider, useCrossDrop } from './src/state/CrossDropProvider';
import { Backdrop } from './src/theme/Backdrop';
import { ThemeProvider, useTheme } from './src/theme/ThemeProvider';
import { spacing } from './src/theme/tokens';

function Root() {
  const t = useTheme();
  const { snapshot, loadError, reload } = useCrossDrop();

  let content: React.ReactNode;
  if (snapshot && !snapshot.prefs.welcomed) {
    content = (
      <>
        <Backdrop mood="idle" />
        <WelcomeScreen />
      </>
    );
  } else if (snapshot) {
    content = <Navigator />;
  } else if (loadError) {
    content = (
      <>
        <Backdrop mood="failed" />
        <View style={styles.center}>
          <Drip pose="failed" size={220} motion="wobble" />
          <Text variant="title" center accessibilityRole="header">
            CrossDrop couldn’t start
          </Text>
          <Text variant="callout" tone="secondary" center>
            The transfer engine didn’t respond. Try again; if it keeps
            happening, restart the app.
          </Text>
          <Button
            title="Try again"
            icon="refresh"
            large
            onPress={reload}
            style={styles.stretch}
          />
        </View>
      </>
    );
  } else {
    content = (
      <>
        <Backdrop mood="idle" />
        <View
          style={styles.center}
          accessible
          accessibilityLabel="Starting CrossDrop"
        >
          <Logo size={64} />
          <Text variant="title" center>
            CrossDrop
          </Text>
          <ActivityIndicator color={t.link} />
        </View>
      </>
    );
  }

  return (
    <View style={[styles.flex, { backgroundColor: t.background }]}>
      <StatusBar barStyle="dark-content" />
      {content}
    </View>
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
  stretch: { alignSelf: 'stretch' },
});
