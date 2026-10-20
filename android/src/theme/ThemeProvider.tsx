import React, { createContext, useContext } from 'react';
import { glassPalette, Palette } from './tokens';

const ThemeContext = createContext<Palette>(glassPalette);

/** Provides the glass palette. Appearance (light/dark) only changes the default wallpaper. */
export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return (
    <ThemeContext.Provider value={glassPalette}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme(): Palette {
  return useContext(ThemeContext);
}
