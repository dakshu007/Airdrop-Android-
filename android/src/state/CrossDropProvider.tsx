import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import * as CrossDrop from '../native/crossdrop';
import type { SharedFile, Snapshot } from '../native/types';

interface CrossDropContextValue {
  snapshot: Snapshot | null;
  /** Set when the first snapshot could not be loaded. */
  loadError: string | null;
  reload: () => void;
  /** Files chosen in-app (not via the share sheet) and not yet sent. */
  selection: SharedFile[];
  addToSelection: (files: SharedFile[]) => void;
  removeFromSelection: (uri: string) => void;
  clearSelection: () => void;
}

const CrossDropContext = createContext<CrossDropContextValue | null>(null);

export function CrossDropProvider({ children }: { children: React.ReactNode }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selection, setSelection] = useState<SharedFile[]>([]);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let mounted = true;
    // Subscribe first so no update is lost between the fetch and the listener.
    const sub = CrossDrop.subscribe(next => {
      if (mounted) {
        setSnapshot(next);
        setLoadError(null);
      }
    });
    CrossDrop.getSnapshot()
      .then(first => {
        if (mounted) {
          setSnapshot(current => current ?? first);
          setLoadError(null);
        }
      })
      .catch((e: unknown) => {
        if (mounted) {
          setLoadError(e instanceof Error ? e.message : String(e));
        }
      });
    return () => {
      mounted = false;
      sub.remove();
    };
  }, [attempt]);

  const reload = useCallback(() => {
    setLoadError(null);
    setAttempt(a => a + 1);
  }, []);

  const addToSelection = useCallback((files: SharedFile[]) => {
    setSelection(current => {
      const seen = new Set(current.map(f => f.uri));
      return [...current, ...files.filter(f => !seen.has(f.uri))];
    });
  }, []);

  const removeFromSelection = useCallback((uri: string) => {
    setSelection(current => current.filter(f => f.uri !== uri));
  }, []);

  const clearSelection = useCallback(() => setSelection([]), []);

  const value = useMemo(
    () => ({
      snapshot,
      loadError,
      reload,
      selection,
      addToSelection,
      removeFromSelection,
      clearSelection,
    }),
    [
      snapshot,
      loadError,
      reload,
      selection,
      addToSelection,
      removeFromSelection,
      clearSelection,
    ],
  );

  return (
    <CrossDropContext.Provider value={value}>
      {children}
    </CrossDropContext.Provider>
  );
}

/**
 * Holds the state a screen sees still while `frozen`: a hidden tab keeps the
 * last state it showed, so state updates (several a second during a
 * transfer) only re-render the visible tab.
 */
export function FreezeWhileHidden({
  frozen,
  children,
}: {
  frozen: boolean;
  children: React.ReactNode;
}) {
  const live = useContext(CrossDropContext);
  const held = useRef(live);
  if (!frozen) held.current = live;
  return (
    <CrossDropContext.Provider value={frozen ? held.current : live}>
      {children}
    </CrossDropContext.Provider>
  );
}

export function useCrossDrop(): CrossDropContextValue {
  const ctx = useContext(CrossDropContext);
  if (!ctx) {
    throw new Error('useCrossDrop must be used inside CrossDropProvider');
  }
  return ctx;
}

/** For screens rendered only after the first snapshot arrived. */
export function useSnapshot(): Snapshot {
  const { snapshot } = useCrossDrop();
  if (!snapshot) {
    throw new Error('Snapshot not loaded yet');
  }
  return snapshot;
}
