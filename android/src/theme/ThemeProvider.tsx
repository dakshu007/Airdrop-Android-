import React, { createContext, useContext } from 'react';
import { useColorScheme } from 'react-native';
import { darkPalette, lightPalette, Palette } from './tokens';

const ThemeContext = createContext<Palette>(lightPalette);

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const scheme = useColorScheme();
  const palette = scheme === 'dark' ? darkPalette : lightPalette;
  return (
    <ThemeContext.Provider value={palette}>{children}</ThemeContext.Provider>
  );
}

export function useTheme(): Palette {
  return useContext(ThemeContext);
}
