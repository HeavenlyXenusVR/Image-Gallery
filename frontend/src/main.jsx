import React from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App.jsx";
import "./styles.css";
import { startRemoteOriginPolling } from "./api.js";

function runtimeBasename() {
  const configured = String(window.IMAGE_GALLERY_BASENAME || "").replace(/\/+$/, "");
  if (configured) return configured;
  const path = window.location.pathname.replace(/\/+$/, "");
  if (window.location.hostname.endsWith("github.io")) {
    const first = path.split("/").filter(Boolean)[0];
    if (first) return `/${first}`;
  }
  if (path.startsWith("/static/react")) return "/static/react";
  return "";
}

function applyRuntimeClasses() {
  const root = document.documentElement;
  const userAgent = navigator.userAgent || "";
  const isOpera = /\bOPR\//.test(userAgent) || /\bOpera\//.test(userAgent);
  const mobileQuery = window.matchMedia("(max-width: 820px), (pointer: coarse)");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  root.classList.toggle("is-opera", isOpera);
  root.classList.toggle("is-mobile-runtime", mobileQuery.matches);
  root.classList.toggle("perf-lite", isOpera || mobileQuery.matches || reducedMotion.matches);
  const refresh = () => {
    root.classList.toggle("is-mobile-runtime", mobileQuery.matches);
    root.classList.toggle("perf-lite", isOpera || mobileQuery.matches || reducedMotion.matches);
  };
  mobileQuery.addEventListener?.("change", refresh);
  reducedMotion.addEventListener?.("change", refresh);
}

applyRuntimeClasses();
startRemoteOriginPolling();

// The service worker + manifest are served from site root by the FastAPI backend
// (see app/routers/pages.py). The static GitHub Pages mirror doesn't have that
// backend, so registering there would just 404 against an unrelated root — skip it.
if ("serviceWorker" in navigator && !window.location.hostname.endsWith("github.io")) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch(() => {});
  });
}

document.addEventListener("contextmenu", (event) => {
  event.preventDefault();
}, { capture: true });

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <BrowserRouter basename={runtimeBasename()}>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);
