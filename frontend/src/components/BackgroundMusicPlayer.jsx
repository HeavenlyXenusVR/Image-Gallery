import { useEffect, useRef, useState } from "react";
import { Music, VolumeX } from "lucide-react";
import { apiFetch } from "../api.js";

const MUTE_STORAGE_KEY = "nyxframe_bg_music_muted";
const NORMAL_VOLUME = 0.35;
const DUCK_VOLUME = 0.06;
const FADE_MS = 400;

// VideoPlayer.jsx dispatches this on every play/pause (native <video> and
// hls.js both funnel through the same onPlay/onPause handlers already
// wired there) so this component doesn't need any prop-drilled or context
// wiring through the whole route tree to know "is a video currently
// playing with sound anywhere on this page" -- it just listens globally.
const VIDEO_PLAYING_EVENT = "nyxframe:video-playing";

function shuffle(list) {
  const copy = list.slice();
  for (let i = copy.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

// Requested feature: an admin-managed shuffled ambient soundtrack that
// plays while visitors browse, fading down (not fully muting -- keeps a
// faint bed under video audio, which reads as smoother than an abrupt cut)
// whenever a video with sound starts, and fading back once it stops.
// Every browser blocks unmuted autoplay outright, so playback only starts
// after the visitor's first real interaction with the page -- there is no
// way to legitimately start audio before that, on any platform.
export function BackgroundMusicPlayer() {
  const audioRef = useRef(null);
  const queueRef = useRef([]);
  const duckedRef = useRef(false);
  const fadeTimerRef = useRef(null);
  const [tracks, setTracks] = useState([]);
  const [muted, setMuted] = useState(() => {
    try {
      return localStorage.getItem(MUTE_STORAGE_KEY) === "1";
    } catch (_error) {
      return false;
    }
  });
  const [started, setStarted] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const data = await apiFetch("/api/background-music");
        if (!cancelled) setTracks(data.tracks || []);
      } catch (_error) {
        // Ambient music is best-effort -- never surface an error toast for it.
      }
    })();
    return () => { cancelled = true; };
  }, []);

  function playNext() {
    const audio = audioRef.current;
    if (!audio) return;
    if (queueRef.current.length === 0) queueRef.current = shuffle(tracks);
    const next = queueRef.current.shift();
    if (!next) return;
    audio.src = next.url;
    audio.play().catch(() => {});
  }

  // Starts on first interaction, once tracks are known.
  useEffect(() => {
    if (started || tracks.length === 0) return;
    const start = () => {
      setStarted(true);
      const audio = audioRef.current;
      if (audio && !muted) {
        audio.volume = NORMAL_VOLUME;
        playNext();
      }
    };
    const events = ["pointerdown", "keydown", "touchstart"];
    events.forEach((event) => window.addEventListener(event, start, { once: true, passive: true }));
    return () => events.forEach((event) => window.removeEventListener(event, start));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tracks, started, muted]);

  // Ducking: fades toward the target volume over FADE_MS instead of
  // snapping, which reads as a jarring volume jump rather than a smooth
  // "making room for the video" dip.
  function fadeTo(target) {
    const audio = audioRef.current;
    if (!audio) return;
    if (fadeTimerRef.current) clearInterval(fadeTimerRef.current);
    const steps = 12;
    const start = audio.volume;
    const delta = (target - start) / steps;
    let i = 0;
    fadeTimerRef.current = setInterval(() => {
      i += 1;
      audio.volume = Math.max(0, Math.min(1, start + delta * i));
      if (i >= steps) clearInterval(fadeTimerRef.current);
    }, FADE_MS / steps);
  }

  useEffect(() => {
    function onVideoPlaying(event) {
      duckedRef.current = Boolean(event.detail?.playing);
      if (!started || muted) return;
      fadeTo(duckedRef.current ? DUCK_VOLUME : NORMAL_VOLUME);
    }
    window.addEventListener(VIDEO_PLAYING_EVENT, onVideoPlaying);
    return () => window.removeEventListener(VIDEO_PLAYING_EVENT, onVideoPlaying);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [started, muted]);

  function toggleMuted() {
    setMuted((current) => {
      const next = !current;
      try { localStorage.setItem(MUTE_STORAGE_KEY, next ? "1" : "0"); } catch (_error) { /* private mode */ }
      const audio = audioRef.current;
      if (audio) {
        if (next) {
          audio.pause();
        } else if (started) {
          audio.volume = duckedRef.current ? DUCK_VOLUME : NORMAL_VOLUME;
          if (!audio.src) playNext(); else audio.play().catch(() => {});
        }
      }
      return next;
    });
  }

  if (tracks.length === 0) return null;

  return (
    <>
      <audio ref={audioRef} onEnded={playNext} style={{ display: "none" }} />
      <button
        type="button"
        className="bg-music-toggle liquid-glass"
        onClick={toggleMuted}
        aria-pressed={!muted}
        title={muted ? "Turn on background music" : "Turn off background music"}
      >
        {muted ? <VolumeX size={16} /> : <Music size={16} />}
      </button>
    </>
  );
}
