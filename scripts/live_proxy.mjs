#!/usr/bin/env node
// Reverse proxy fronting the live tunnel: routes requests for endpoints
// already ported to the Lua rewrite (lua/main.lua) there, and falls back to
// the existing Python/FastAPI backend (app/main.py) for everything else.
//
// This lets the live site (gallery.xenusanimations.studio, via the
// image-gallery-cloudflared tunnel) start using the Lua backend for ported
// routes without breaking anything not yet ported — the tunnel's ingress
// config points at this proxy's port instead of the Python backend's port
// directly; Python keeps running unchanged on its own port behind this.
//
// PORTED_ROUTES below must be kept in sync by hand with lua/main.lua's own
// httpd.route(...) registrations — there is no shared source of truth
// between the two languages. Re-run this comparison whenever a new route is
// ported:
//   grep -oP 'httpd\.route\("\K[A-Z]+", "[^"]+' lua/main.lua
//
// See TODO.md for what is NOT yet ported (and therefore always falls
// through to Python here).

import http from "node:http";
import net from "node:net";
import { URL } from "node:url";

const PROXY_PORT = Number(process.env.GALLERY_PROXY_PORT || 8791);
const LUA_TARGET = new URL(process.env.GALLERY_LUA_TARGET || "http://127.0.0.1:8789");
const PY_TARGET = new URL(process.env.GALLERY_PY_TARGET || "http://127.0.0.1:8788");

// Mirrors lua/src/httpd.lua's split_path_pattern(): ":name" segments match
// exactly one non-"/" path segment.
function patternToRegex(pattern) {
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/:[^/]+/g, "([^/]+)");
  return new RegExp(`^${escaped}$`);
}

const PORTED_ROUTES = [
  "GET /api/health",
  "GET /api/live/checks",
  "POST /api/auth/register",
  "POST /api/auth/login",
  "POST /api/auth/2fa/verify",
  "POST /api/auth/logout",
  "GET /api/me",
  "PATCH /api/me/profile",
  "PATCH /api/me/settings",
  "GET /api/appearance/presets",
  "GET /api/categories",
  "POST /api/categories",
  "GET /api/media",
  "POST /api/media",
  "POST /api/media/bulk",
  "POST /api/media/bulk-delete",
  "GET /api/media/:media_id",
  "PATCH /api/media/:media_id",
  "DELETE /api/media/:media_id",
  "POST /api/media/:media_id/like",
  "POST /api/media/:media_id/bookmark",
  "POST /api/media/:media_id/comments",
  "POST /api/media/:media_id/react",
  "GET /api/media/:media_id/similar",
  "PATCH /api/media/:media_id/controls",
  "POST /api/media/:media_id/restore",
  "POST /api/media/:media_id/report",
  "DELETE /api/comments/:comment_id",
  "GET /api/media/:media_id/thumb",
  "GET /api/media/:media_id/file",
  "GET /api/media/:media_id/preview",
  "GET /api/media/:media_id/download",
  "GET /api/users/:user_id/avatar",
  "GET /api/me/2fa/status",
  "POST /api/me/2fa/enroll",
  "POST /api/me/2fa/confirm",
  "POST /api/me/2fa/disable",
  "GET /api/tags",
  "GET /api/site/announcement",
  "GET /api/notifications",
  "GET /api/notifications/unread-count",
  "POST /api/notifications/read-all",
  "POST /api/notifications/:notification_id/read",
  "GET /api/messages/threads",
  "GET /api/messages/:user_id",
  "POST /api/messages/:user_id",
  "GET /api/collections/suggestions",
  "GET /api/collections",
  "POST /api/collections",
  "GET /api/collections/:collection_id",
  "POST /api/collections/:collection_id/items",
  "GET /api/stats",
  "GET /api/admin/reports",
  "POST /api/admin/reports/:report_id/resolve",
  "POST /api/admin/users/:user_id/ban",
  "POST /api/admin/users/:user_id/unban",
  "GET /api/admin/audit-log",
  "GET /api/admin/flagged-media",
  "POST /api/admin/flagged-media/:media_id/resolve",
  "PATCH /api/admin/site-settings",
  "GET /api/ai/vision/status",
  "GET /api/ai/vision/training/export",
  "GET /api/ai/vision/training",
].map((entry) => {
  const [method, pattern] = entry.split(" ");
  return { method, pattern, regex: patternToRegex(pattern) };
});

function isPortedPath(pathname) {
  return PORTED_ROUTES.some((route) => route.regex.test(pathname));
}

function isPorted(method, pathname) {
  return PORTED_ROUTES.some((route) => route.method === method && route.regex.test(pathname));
}

// OPTIONS preflight doesn't carry the real method — route it wherever a rule
// exists for that path at all, so CORS preflight and the real request that
// follows always land on the same backend.
function pickTarget(method, pathname) {
  const ported = method === "OPTIONS" ? isPortedPath(pathname) : isPorted(method, pathname);
  return ported ? LUA_TARGET : PY_TARGET;
}

// Hop-by-hop headers must not be forwarded (RFC 7230 §6.1).
const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailers", "transfer-encoding", "upgrade",
]);

function filteredHeaders(headers) {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP.has(key.toLowerCase())) out[key] = value;
  }
  return out;
}

const server = http.createServer((req, res) => {
  const pathname = (req.url || "/").split("?")[0];
  const target = pickTarget(req.method, pathname);

  const proxyReq = http.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port,
      path: req.url,
      method: req.method,
      headers: filteredHeaders(req.headers),
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode || 502, filteredHeaders(proxyRes.headers));
      proxyRes.pipe(res);
    },
  );

  proxyReq.on("error", (err) => {
    console.error(`[live_proxy] upstream error for ${req.method} ${pathname} -> ${target.origin}: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json" });
    }
    res.end(JSON.stringify({ detail: "Upstream backend unavailable." }));
  });
  req.on("error", () => proxyReq.destroy());

  req.pipe(proxyReq);
});

// No route in either backend currently upgrades to WebSocket in production
// (see this file's header comment), but a bare http.Server never fires its
// normal 'request' handler for an Upgrade request — without this listener
// such a connection would just hang until timeout instead of failing fast
// or working. Relay the raw TCP stream to whichever backend would have
// handled the path as a normal request, so behavior degrades to "whatever
// that backend does with an unhandled Upgrade" instead of a stuck socket.
server.on("upgrade", (req, clientSocket, head) => {
  const pathname = (req.url || "/").split("?")[0];
  const target = pickTarget(req.method, pathname);
  const upstreamSocket = net.connect(Number(target.port), target.hostname, () => {
    const headerLines = [`${req.method} ${req.url} HTTP/1.1`];
    for (const [key, value] of Object.entries(req.headers)) {
      headerLines.push(`${key}: ${value}`);
    }
    upstreamSocket.write(headerLines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) upstreamSocket.write(head);
    upstreamSocket.pipe(clientSocket);
    clientSocket.pipe(upstreamSocket);
  });
  upstreamSocket.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstreamSocket.destroy());
});

server.listen(PROXY_PORT, "127.0.0.1", () => {
  console.log(`[live_proxy] listening on 127.0.0.1:${PROXY_PORT}`);
  console.log(`[live_proxy] ported routes -> ${LUA_TARGET.origin}, everything else -> ${PY_TARGET.origin}`);
});
