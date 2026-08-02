#!/usr/bin/env luajit
-- Lua port of the old scripts/write-root-shell.mjs -- this is the one Node
-- tool that had no real dependency on Node/npm (no JSX, no bundling, just
-- writing two static files), so it's a genuinely safe, low-risk piece to
-- move off the JS toolchain. See package.json's "build" script for how
-- this is invoked (after `vite build`, which still requires Node -- this
-- only replaces the second step, not the frontend build itself).
--
-- GitHub Pages is static-only hosting and can't run the Lua backend, which
-- now serves the built React SPA directly at gallery.xenusanimations.studio
-- (see lua/src/static.lua) -- there's no separate frontend build to publish
-- here anymore, same as the SwarmPanel-strictly-Lua rewrite. This just
-- writes a meta-refresh redirect so old bookmarks/links to the GitHub Pages
-- URL still land somewhere useful instead of a bare 404.

local shell = [[<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta http-equiv="refresh" content="0; url=https://gallery.xenusanimations.studio/" />
    <title>Image Gallery</title>
    <link rel="canonical" href="https://gallery.xenusanimations.studio/" />
  </head>
  <body>
    <!--
      GitHub Pages is static-only hosting and can't run the Lua backend that
      now renders Image Gallery directly (see the Lua rewrite -- there is no
      separate frontend build to publish here anymore). This page exists
      only so old bookmarks/links to the GitHub Pages URL still land
      somewhere useful instead of a bare 404.
    -->
    <p>Image Gallery has moved. Redirecting to
      <a href="https://gallery.xenusanimations.studio/">https://gallery.xenusanimations.studio/</a>...
    </p>
  </body>
</html>
]]

for _, name in ipairs({ "index.html", "404.html" }) do
  local f = assert(io.open(name, "w"))
  f:write(shell)
  f:close()
end
