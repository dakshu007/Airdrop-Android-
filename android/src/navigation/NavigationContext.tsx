import { createContext, useContext } from 'react';

export type TabKey = 'nearby' | 'activity' | 'devices' | 'settings';

export interface NavigationValue {
  tab: TabKey;
  navigate: (tab: TabKey) => void;
}

export const NavigationContext = createContext<NavigationValue>({
  tab: 'nearby',
  navigate: () => {},
});

export function useNavigation(): NavigationValue {
  return useContext(NavigationContext);
}
