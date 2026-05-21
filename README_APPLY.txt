Image Gallery Collections + Liked Grid Fix

What changed:
- Liked/feed grids now use CSS auto-fill instead of auto-fit so a single liked post no longer stretches across the whole page.
- Every media card now has an Add to collection action.
- Media detail Post Actions now includes Add to Collection.
- Your own collection detail pages now include an Add existing posts search panel, so empty collections can be filled without re-uploading media.
- Collection saves clear frontend API cache so counts/detail views refresh cleanly.

Apply:
1. Copy the included files into the Image Gallery project root, preserving folders.
2. If you copy the built app/static/react assets and root index.html/404.html, it is ready to serve.
3. If you prefer rebuilding locally, copy only frontend/src/* changes, then run:
   npm run build

Validation run in sandbox:
- python -m compileall -q app
- npm run build

Note:
- The Playwright mock UI test could not run in the sandbox because the Playwright Chromium browser binary is not installed there.
