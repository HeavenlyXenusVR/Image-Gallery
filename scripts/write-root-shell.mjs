import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

// GitHub Pages is static-only hosting and can't run the Lua backend, which
// now serves the built React SPA directly at gallery.xenusanimations.studio
// (see lua/src/static.lua) -- there's no separate frontend build to publish
// here anymore, same as the SwarmPanel-strictly-Lua rewrite. This just
// writes a meta-refresh redirect so old bookmarks/links to the GitHub Pages
// URL still land somewhere useful instead of a bare 404.
const shell = `<!doctype html>
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
`;

writeFileSync(resolve("index.html"), shell);
writeFileSync(resolve("404.html"), shell);
