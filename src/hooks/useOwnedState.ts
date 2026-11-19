import { useCallback, useRef, useState, type Dispatch, type SetStateAction } from 'react';

// Values carry their owner into the render that consumes them. Passive-effect
// resets alone cannot prevent an old snapshot from seeding a new owner's cache.
export function useOwnedState<T>(owner: unknown, isCurrent: () => boolean, initial: T): [T, Dispatch<SetStateAction<T>>] {
  const [state, setState] = useState<{ owner: unknown; value: T } | null>(null);
  const currentOwner = useRef(owner);
  currentOwner.current = owner;
  const setOwned = useCallback((update: SetStateAction<T>) => {
    if (currentOwner.current !== owner || !isCurrent()) return;
    setState(previous => {
      if (currentOwner.current !== owner || !isCurrent()) return previous;
      const value = previous && previous.owner === owner ? previous.value : initial;
      const next = typeof update === 'function' ? (update as (current: T) => T)(value) : update;
      if (Object.is(value, next) && (!previous || previous.owner === owner)) return previous;
      return { owner, value: next };
    });
  }, [initial, isCurrent, owner]);
  return [state && state.owner === owner && isCurrent() ? state.value : initial, setOwned];
}
