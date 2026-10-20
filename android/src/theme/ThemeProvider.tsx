import React, { createContext, useContext } from 'react';
import { mintPalette, Palette } from './tokens';

const ThemeContext = createContext<Palette>(mintPalette);

/** Provides the Mint Air palette. A dark "night mint" variant is planned, not built yet. */
export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return (
    <ThemeContext.Provider value={mintPalette}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme(): Palette {
  return useContext(ThemeContext);
}
