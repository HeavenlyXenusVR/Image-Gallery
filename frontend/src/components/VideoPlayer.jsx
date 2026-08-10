import { useCallback, useEffect, useRef, useState } from "react";
import {
  AlertCircle,
  Gauge,
  Loader2,
  Maximize,
  Minimize,
  Pause,
  PictureInPicture2,
  Play,
  RefreshCw,
  Repeat,
  SkipBack,
  SkipForward,
  Volume1,
  Volume2,
  VolumeX,
} from "lucide-react";

function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2];

export function VideoPlayer({ src, poster, quality, onQualityChange, qualityOptions, title }) {
  const videoRef = useRef(null);
  const containerRef = useRef(null);
  const controlsHideTimer = useRef(null);
  const seekBarRef = useRef(null);
  const volumeBarRef = useRef(null);

  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [showControls, setShowControls] = useState(true);
  const [buffering, setBuffering] = useState(false);
  const [bufferingLong, setBufferingLong] = useState(false);
  const [error, setError] = useState(null);
  const [speed, setSpeed] = useState(1);
  const [showSpeedMenu, setShowSpeedMenu] = useState(false);
  const [showQualityMenu, setShowQualityMenu] = useState(false);
  const [seekHover, setSeekHover] = useState(null); // { x, time }
  const [pip, setPip] = useState(false);
  const [loop, setLoop] = useState(false);
  const [showRemaining, setShowRemaining] = useState(false);
  const [seeking, setSeeking] = useState(false);

  // ─── Seek-restore state for quality switching ────────────────────────────────
  const pendingRestoreRef = useRef(null); // { time, wasPlaying }
  const bufferingTimerRef = useRef(null);
  const durationRef = useRef(0);

  // ─── Auto-play tracking ──────────────────────────────────────────────────────
  // Set to true once the user has clicked play; thereafter onCanPlay will resume.
  const shouldAutoPlayRef = useRef(false);

  // ─── Controls auto-hide ─────────────────────────────────────────────────────
  const scheduleHide = useCallback(() => {
    if (controlsHideTimer.current) clearTimeout(controlsHideTimer.current);
    controlsHideTimer.current = setTimeout(() => {
      if (videoRef.current && !videoRef.current.paused) setShowControls(false);
    }, 2500);
  }, []);

  const revealControls = useCallback(() => {
    setShowControls(true);
    scheduleHide();
  }, [scheduleHide]);

  // ─── Video event handlers ────────────────────────────────────────────────────
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const onPlay = () => { setPlaying(true); setBuffering(false); scheduleHide(); };
    const onPause = () => { setPlaying(false); setShowControls(true); if (controlsHideTimer.current) clearTimeout(controlsHideTimer.current); };
    const onTimeUpdate = () => {
      setCurrentTime(video.currentTime);
      if (video.buffered.length > 0) setBuffered(video.buffered.end(video.buffered.length - 1));
    };
    const onDurationChange = () => { const d = video.duration || 0; setDuration(d); durationRef.current = d; };
    const onWaiting = () => {
      setBuffering(true);
      if (bufferingTimerRef.current) clearTimeout(bufferingTimerRef.current);
      bufferingTimerRef.current = setTimeout(() => setBufferingLong(true), 3000);
    };
    const onCanPlay = () => {
      setBuffering(false);
      setBufferingLong(false);
      if (bufferingTimerRef.current) { clearTimeout(bufferingTimerRef.current); bufferingTimerRef.current = null; }
      // Restore seek position after quality switch
      if (pendingRestoreRef.current) {
        const { time, wasPlaying } = pendingRestoreRef.current;
        pendingRestoreRef.current = null;
        if (time > 0) video.currentTime = time;
        if (wasPlaying) video.play().catch(() => {});
        return;
      }
      // Auto-play if the user had previously started playing
      if (shouldAutoPlayRef.current) {
        video.play().catch(() => {});
      }
    };
    const onError = () => {
      const vid = videoRef.current;
      const code = vid?.error?.code;
      if (code === 2) setError("Network error — check your connection and try again.");
      else if (code === 3) setError("Decoding error — the video format may not be supported.");
      else if (code === 4) {
        // MEDIA_ERR_SRC_NOT_SUPPORTED — Firefox rejects non-browser-safe formats.
        // If we're on high/original quality and a lower quality is available,
        // automatically fall back to 1080p so the video can still play.
        const fallback = qualityOptions && qualityOptions.find(([v]) => v === "1080p" || v === "720p");
        if (
          onQualityChange &&
          (quality === "high" || quality === "original" || !quality) &&
          fallback
        ) {
          setError(`This format isn't supported by your browser. Switching to ${fallback[1] || fallback[0]}…`);
          onQualityChange(fallback[0]);
        } else {
          setError("This format isn't supported by your browser. Try switching to a lower quality.");
        }
      } else setError("Playback error — the video could not be loaded.");
    };
    const onEnded = () => { setPlaying(false); setShowControls(true); };
    const onVolumeChange = () => { setVolume(video.volume); setMuted(video.muted); };
    const onFullscreenChange = () => setFullscreen(Boolean(document.fullscreenElement));
    const onPipEnter = () => setPip(true);
    const onPipLeave = () => setPip(false);

    video.addEventListener("play", onPlay);
    video.addEventListener("pause", onPause);
    video.addEventListener("timeupdate", onTimeUpdate);
    video.addEventListener("durationchange", onDurationChange);
    video.addEventListener("waiting", onWaiting);
    video.addEventListener("canplay", onCanPlay);
    video.addEventListener("error", onError);
    video.addEventListener("ended", onEnded);
    video.addEventListener("volumechange", onVolumeChange);
    video.addEventListener("enterpictureinpicture", onPipEnter);
    video.addEventListener("leavepictureinpicture", onPipLeave);
    document.addEventListener("fullscreenchange", onFullscreenChange);

    return () => {
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
      video.removeEventListener("timeupdate", onTimeUpdate);
      video.removeEventListener("durationchange", onDurationChange);
      video.removeEventListener("waiting", onWaiting);
      video.removeEventListener("canplay", onCanPlay);
      video.removeEventListener("error", onError);
      video.removeEventListener("ended", onEnded);
      video.removeEventListener("volumechange", onVolumeChange);
      video.removeEventListener("enterpictureinpicture", onPipEnter);
      video.removeEventListener("leavepictureinpicture", onPipLeave);
      document.removeEventListener("fullscreenchange", onFullscreenChange);
      clearTimeout(controlsHideTimer.current);
      if (bufferingTimerRef.current) clearTimeout(bufferingTimerRef.current);
    };
  }, [scheduleHide]);

  // On src change: save position/playing state, (re)attach the stream,
  // restore after canplay. `src` now points at a real HLS playlist
  // (master.m3u8 for adaptive, or a specific quality's own playlist.m3u8),
  // not a single progressively-downloaded file — Safari plays that
  // natively via <video src>, but Chrome/Firefox have no built-in HLS
  // support at all, hence hls.js: it demuxes segments into a MediaSource
  // buffer and dispatches the SAME native media events (canplay,
  // durationchange, waiting, timeupdate...) this component already
  // listens for above, so only the *attachment* mechanism differs — the
  // rest of this component doesn't need to know which path is active.
  const hlsRef = useRef(null);
  const prevSrcRef = useRef(src);
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !src) return;
    let cancelled = false;
    setError(null);
    setBufferingLong(false);
    if (bufferingTimerRef.current) { clearTimeout(bufferingTimerRef.current); bufferingTimerRef.current = null; }

    const isQualitySwitch = Boolean(prevSrcRef.current && prevSrcRef.current !== src);
    let pendingRestore = null;
    if (isQualitySwitch) {
      const savedTime = video.currentTime || 0;
      const wasPlaying = !video.paused;
      if (savedTime > 0 || wasPlaying) pendingRestore = { time: savedTime, wasPlaying };
      video.pause();
    } else {
      setCurrentTime(0);
      setBuffered(0);
      setPlaying(false);
    }
    if (pendingRestore) pendingRestoreRef.current = pendingRestore;
    prevSrcRef.current = src;

    if (hlsRef.current) {
      hlsRef.current.destroy();
      hlsRef.current = null;
    }

    const isHlsSrc = src.includes(".m3u8");
    const hasNativeHls = video.canPlayType("application/vnd.apple.mpegurl") !== "";
    if (isHlsSrc && !hasNativeHls) {
      // Deferred so pages with no video playing never pay hls.js's bundle
      // cost — only actually loaded once a real HLS source needs it.
      import("hls.js").then(({ default: Hls }) => {
        if (cancelled || !Hls.isSupported() || videoRef.current !== video) return;
        const hls = new Hls({ enableWorker: true });
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (!data.fatal) return;
          if (data.type === Hls.ErrorTypes.NETWORK_ERROR) setError("Network error — check your connection and try again.");
          else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) setError("Decoding error — the video format may not be supported.");
          else setError("Playback error — the video could not be loaded.");
        });
        hls.loadSource(src);
        hls.attachMedia(video);
        hlsRef.current = hls;
      });
    } else {
      video.src = src;
      video.load();
    }

    return () => { cancelled = true; };
  }, [src]);

  useEffect(() => () => { if (hlsRef.current) hlsRef.current.destroy(); }, []);

  // Sync loop attribute on video element when state changes
  useEffect(() => {
    const video = videoRef.current;
    if (video) video.loop = loop;
  }, [loop]);

  // Document-level mouseup to cancel drag-seek
  useEffect(() => {
    if (!seeking) return;
    const up = () => setSeeking(false);
    document.addEventListener("mouseup", up);
    document.addEventListener("touchend", up, { passive: true });
    return () => {
      document.removeEventListener("mouseup", up);
      document.removeEventListener("touchend", up);
    };
  }, [seeking]);

  // Touch seek — attached as non-passive so preventDefault() works on iOS Safari.
  // Uses refs (videoRef, seekBarRef, durationRef) to avoid stale closures since
  // the effect only re-runs when revealControls changes (which is stable).
  useEffect(() => {
    const bar = seekBarRef.current;
    if (!bar) return;
    const getTouchFraction = (e) => {
      const touch = e.touches[0];
      if (!touch) return null;
      const rect = bar.getBoundingClientRect();
      return clamp((touch.clientX - rect.left) / rect.width, 0, 1);
    };
    const applySeek = (fraction) => {
      const video = videoRef.current;
      const dur = durationRef.current;
      if (!video || !dur || fraction === null) return;
      video.currentTime = clamp(fraction * dur, 0, dur);
    };
    const onTouchStart = (e) => {
      e.preventDefault();
      setSeeking(true);
      applySeek(getTouchFraction(e));
      revealControls();
    };
    const onTouchMove = (e) => {
      e.preventDefault();
      applySeek(getTouchFraction(e));
    };
    bar.addEventListener("touchstart", onTouchStart, { passive: false });
    bar.addEventListener("touchmove", onTouchMove, { passive: false });
    return () => {
      bar.removeEventListener("touchstart", onTouchStart);
      bar.removeEventListener("touchmove", onTouchMove);
    };
  }, [revealControls]);

  // ─── Playback controls ───────────────────────────────────────────────────────
  function togglePlay() {
    const video = videoRef.current;
    if (!video || error) return;
    if (video.paused) {
      shouldAutoPlayRef.current = true;
      video.play().catch(() => {});
    } else {
      video.pause();
    }
  }

  function seek(fraction) {
    const video = videoRef.current;
    if (!video || !duration) return;
    video.currentTime = clamp(fraction * duration, 0, duration);
  }

  function nudge(seconds) {
    const video = videoRef.current;
    if (!video || !duration) return;
    video.currentTime = clamp(video.currentTime + seconds, 0, duration);
  }

  function toggleMute() {
    const video = videoRef.current;
    if (!video) return;
    video.muted = !video.muted;
  }

  function changeVolume(fraction) {
    const video = videoRef.current;
    if (!video) return;
    const v = clamp(fraction, 0, 1);
    video.volume = v;
    video.muted = v === 0;
  }

  function setPlaybackSpeed(s) {
    const video = videoRef.current;
    if (video) video.playbackRate = s;
    setSpeed(s);
    setShowSpeedMenu(false);
  }

  function toggleFullscreen() {
    const container = containerRef.current;
    if (!container) return;
    if (!document.fullscreenElement) {
      container.requestFullscreen().catch(() => {});
    } else {
      document.exitFullscreen().catch(() => {});
    }
  }

  function togglePip() {
    const video = videoRef.current;
    if (!video) return;
    if (document.pictureInPictureElement) {
      document.exitPictureInPicture().catch(() => {});
    } else {
      video.requestPictureInPicture().catch(() => {});
    }
  }

  function retry() {
    const video = videoRef.current;
    if (!video) return;
    setError(null);
    shouldAutoPlayRef.current = true;
    video.load();
    video.play().catch(() => {});
  }

  // ─── Seek bar interaction ────────────────────────────────────────────────────
  function seekBarFraction(clientX) {
    const bar = seekBarRef.current;
    if (!bar) return 0;
    const rect = bar.getBoundingClientRect();
    return clamp((clientX - rect.left) / rect.width, 0, 1);
  }

  function onSeekMouseDown(event) {
    setSeeking(true);
    seek(seekBarFraction(event.clientX));
    revealControls();
  }

  function onSeekMouseMove(event) {
    const bar = seekBarRef.current;
    if (!bar) return;
    const rect = bar.getBoundingClientRect();
    const fraction = clamp((event.clientX - rect.left) / rect.width, 0, 1);
    setSeekHover({ x: event.clientX - rect.left, time: fraction * duration });
    if (seeking) seek(fraction);
  }

  function onSeekMouseUp() {
    setSeeking(false);
  }

  // ─── Volume bar interaction ──────────────────────────────────────────────────
  function volumeBarFraction(event) {
    const bar = volumeBarRef.current;
    if (!bar) return 1;
    const rect = bar.getBoundingClientRect();
    return clamp((event.clientX - rect.left) / rect.width, 0, 1);
  }

  // ─── Keyboard shortcuts ──────────────────────────────────────────────────────
  // Use a ref to always see fresh volume so the effect never needs to re-run
  const volumeRef = useRef(volume);
  volumeRef.current = volume;

  useEffect(() => {
    function onKey(event) {
      if (!containerRef.current) return;
      if (event.target.tagName === "INPUT" || event.target.tagName === "TEXTAREA" || event.target.tagName === "SELECT") return;
      if (!containerRef.current.contains(document.activeElement) && document.activeElement !== document.body) return;
      switch (event.code) {
        case "Space": event.preventDefault(); togglePlay(); break;
        case "ArrowLeft": event.preventDefault(); nudge(-10); revealControls(); break;
        case "ArrowRight": event.preventDefault(); nudge(10); revealControls(); break;
        case "ArrowUp": event.preventDefault(); changeVolume(volumeRef.current + 0.1); revealControls(); break;
        case "ArrowDown": event.preventDefault(); changeVolume(volumeRef.current - 0.1); revealControls(); break;
        case "KeyM": toggleMute(); break;
        case "KeyF": toggleFullscreen(); break;
        case "KeyP": togglePip(); break;
        case "KeyL": setLoop((v) => !v); break;
        case "Home": event.preventDefault(); seek(0); revealControls(); break;
        case "End": event.preventDefault(); seek(0.95); revealControls(); break;
        default: {
          // 0–9 keys: seek to 0%–90%
          if (event.key >= "0" && event.key <= "9") {
            event.preventDefault();
            seek(Number(event.key) / 10);
            revealControls();
          }
          break;
        }
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [revealControls]);

  const progressPct = duration > 0 ? (currentTime / duration) * 100 : 0;
  const bufferedPct = duration > 0 ? (buffered / duration) * 100 : 0;
  const volumePct = muted ? 0 : volume * 100;
  const VolumeIcon = muted || volume === 0 ? VolumeX : volume < 0.5 ? Volume1 : Volume2;

  return (
    <div
      ref={containerRef}
      className={`vp-root${fullscreen ? " vp-fullscreen" : ""}${!showControls && playing ? " vp-controls-hidden" : ""}`}
      onMouseMove={revealControls}
      onMouseLeave={() => { if (playing) setShowControls(false); }}
      onClick={(e) => { if (e.target === containerRef.current || e.target === videoRef.current) togglePlay(); }}
      tabIndex={-1}
    >
      {/* Video element */}
      <video
        ref={videoRef}
        className="vp-video"
        poster={poster}
        playsInline
        preload="metadata"
        onClick={(e) => { e.stopPropagation(); togglePlay(); }}
        onDoubleClick={toggleFullscreen}
      />

      {/* Buffering spinner */}
      {buffering && !error && (
        <div className="vp-spinner-wrap" aria-label={bufferingLong ? "Transcoding" : "Buffering"}>
          <div className="vp-spinner" />
          {bufferingLong && (
            <div className="vp-transcoding-msg">
              <Loader2 size={14} className="vp-transcoding-spin" />
              Transcoding&hellip; this may take a moment
            </div>
          )}
        </div>
      )}

      {/* Error overlay */}
      {error && (
        <div className="vp-error">
          <AlertCircle size={36} />
          <p>{error}</p>
          <button type="button" className="vp-retry-btn" onClick={retry}>
            <RefreshCw size={16} /> Retry
          </button>
        </div>
      )}

      {/* Big centre play icon (shows briefly on pause) */}
      {!playing && !error && !buffering && currentTime === 0 && (
        <button type="button" className="vp-big-play" onClick={togglePlay} aria-label="Play">
          <Play size={48} />
        </button>
      )}

      {/* Controls overlay */}
      <div className="vp-controls" onClick={(e) => e.stopPropagation()}>
        {/* Seek bar */}
        <div className="vp-seek-wrap">
          {seekHover && duration > 0 && (
            <div className="vp-seek-tooltip" style={{ left: `${clamp(seekHover.x, 28, 9999)}px` }}>
              {formatTime(seekHover.time)}
            </div>
          )}
          <div
            ref={seekBarRef}
            className="vp-seek-bar"
            role="slider"
            aria-label="Seek"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(progressPct)}
            onMouseDown={onSeekMouseDown}
            onMouseMove={onSeekMouseMove}
            onMouseUp={onSeekMouseUp}
            onMouseLeave={() => setSeekHover(null)}
          >
            <div className="vp-seek-track">
              <div className="vp-seek-buffered" style={{ width: `${bufferedPct}%` }} />
              <div className="vp-seek-played" style={{ width: `${progressPct}%` }}>
                <div className="vp-seek-thumb" />
              </div>
            </div>
          </div>
        </div>

        {/* Bottom controls row */}
        <div className="vp-bottom">
          {/* Left cluster */}
          <div className="vp-cluster">
            <button type="button" className="vp-btn" onClick={() => nudge(-10)} title="Back 10s" aria-label="Seek back 10 seconds">
              <SkipBack size={18} />
            </button>
            <button type="button" className="vp-btn vp-play-btn" onClick={togglePlay} aria-label={playing ? "Pause" : "Play"}>
              {playing ? <Pause size={22} /> : <Play size={22} />}
            </button>
            <button type="button" className="vp-btn" onClick={() => nudge(10)} title="Forward 10s" aria-label="Seek forward 10 seconds">
              <SkipForward size={18} />
            </button>

            {/* Volume */}
            <div className="vp-volume-group">
              <button type="button" className="vp-btn" onClick={toggleMute} aria-label={muted ? "Unmute" : "Mute"}>
                <VolumeIcon size={18} />
              </button>
              <div
                ref={volumeBarRef}
                className="vp-volume-bar"
                role="slider"
                aria-label="Volume"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={Math.round(volumePct)}
                onClick={(e) => changeVolume(volumeBarFraction(e))}
              >
                <div className="vp-volume-track">
                  <div className="vp-volume-filled" style={{ width: `${volumePct}%` }} />
                  <div className="vp-volume-thumb" style={{ left: `${volumePct}%` }} />
                </div>
              </div>
            </div>

            {/* Time */}
            <span
              className="vp-time"
              onClick={() => setShowRemaining((v) => !v)}
              style={{ cursor: "pointer" }}
              title={showRemaining ? "Show elapsed time" : "Show remaining time"}
            >
              {showRemaining && duration > 0
                ? `-${formatTime(Math.max(0, duration - currentTime))} / ${formatTime(duration)}`
                : `${formatTime(currentTime)} / ${formatTime(duration)}`}
            </span>
          </div>

          {/* Right cluster */}
          <div className="vp-cluster">
            {/* Loop */}
            <button
              type="button"
              className={`vp-btn${loop ? " active" : ""}`}
              onClick={() => setLoop((v) => !v)}
              title="Loop"
              aria-label="Loop video"
            >
              <Repeat size={18} />
            </button>

            {/* Speed */}
            <div className="vp-menu-wrap">
              <button
                type="button"
                className={`vp-btn vp-speed-btn${showSpeedMenu ? " active" : ""}`}
                onClick={() => { setShowSpeedMenu((v) => !v); setShowQualityMenu(false); }}
                title="Playback speed"
                aria-label="Playback speed"
              >
                <Gauge size={18} />
                <span className="vp-speed-label">{speed}×</span>
              </button>
              {showSpeedMenu && (
                <div className="vp-menu vp-menu-up">
                  {SPEEDS.map((s) => (
                    <button
                      key={s}
                      type="button"
                      className={`vp-menu-item${speed === s ? " vp-menu-item-active" : ""}`}
                      onClick={() => setPlaybackSpeed(s)}
                    >
                      {s}×
                    </button>
                  ))}
                </div>
              )}
            </div>

            {/* Quality */}
            {qualityOptions && qualityOptions.length > 0 && onQualityChange && (
              <div className="vp-menu-wrap">
                <button
                  type="button"
                  className={`vp-btn${showQualityMenu ? " active" : ""}`}
                  onClick={() => { setShowQualityMenu((v) => !v); setShowSpeedMenu(false); }}
                  title="Quality"
                  aria-label="Video quality"
                >
                  <span className="vp-quality-label">{(qualityOptions.find(([v]) => v === quality) || [])[1] || quality || "HD"}</span>
                </button>
                {showQualityMenu && (
                  <div className="vp-menu vp-menu-up">
                    {qualityOptions.map(([value, label]) => (
                      <button
                        key={value}
                        type="button"
                        className={`vp-menu-item${quality === value ? " vp-menu-item-active" : ""}`}
                        onClick={() => { onQualityChange(value); setShowQualityMenu(false); }}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* PiP */}
            {"pictureInPictureEnabled" in document && (
              <button type="button" className={`vp-btn${pip ? " active" : ""}`} onClick={togglePip} title="Picture in Picture" aria-label="Picture in Picture">
                <PictureInPicture2 size={18} />
              </button>
            )}

            {/* Fullscreen */}
            <button type="button" className="vp-btn" onClick={toggleFullscreen} title={fullscreen ? "Exit fullscreen" : "Fullscreen"} aria-label={fullscreen ? "Exit fullscreen" : "Fullscreen"}>
              {fullscreen ? <Minimize size={18} /> : <Maximize size={18} />}
            </button>
          </div>
        </div>
      </div>

      {/* Close speed/quality menus on outside click */}
      {(showSpeedMenu || showQualityMenu) && (
        <div className="vp-menu-overlay" onClick={() => { setShowSpeedMenu(false); setShowQualityMenu(false); }} />
      )}
    </div>
  );
}
