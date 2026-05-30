import { useEffect, useRef } from "react";

export function useLiveRefresh(callback, { enabled = true, interval = 20_000, immediate = false } = {}) {
  const callbackRef = useRef(callback);

  useEffect(() => {
    callbackRef.current = callback;
  }, [callback]);

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return undefined;
    let stopped = false;
    let timer = 0;
    let inFlight = false;

    const run = () => {
      if (stopped || inFlight || document.hidden || navigator.onLine === false) return;
      inFlight = true;
      Promise.resolve(callbackRef.current?.())
        .catch(() => {})
        .finally(() => {
          inFlight = false;
        });
    };

    if (immediate) run();
    timer = window.setInterval(run, interval);
    const onVisibilityChange = () => { if (!document.hidden) run(); };
    document.addEventListener("visibilitychange", onVisibilityChange);
    window.addEventListener("online", run);

    return () => {
      stopped = true;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("online", run);
    };
  }, [enabled, immediate, interval]);
}
