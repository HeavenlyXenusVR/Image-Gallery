# Image Gallery Gemini + Deep Audit Patch

## AI / vision routing
- Treats `gemini`, `google`, and `google-gemini` as first-class AI providers.
- Sets `.env` to `GALLERY_AI_PROVIDER=gemini` without changing or printing any API key.
- Uses `GALLERY_GEMINI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY` for Gemini vision.
- Uses `GALLERY_GEMINI_MODEL` / `GEMINI_MODEL`, defaulting to `gemini-2.5-flash-lite`.
- Prevents Ollama from hijacking vision calls just because `GALLERY_OLLAMA_MODEL` exists.
- Sanitizes AI provider error messages so API keys are not echoed into UI/log fallbacks.

## Frontend hardening
- Adds API fetch timeouts so dead tunnels do not hang React pages indefinitely.
- Validates `live-config.json` origins before trusting them.
- Rejects unsafe protocols and mixed HTTPS-to-public-HTTP origins.
- Bumps API cache version to invalidate stale cached data.
- Sanitizes profile website links client-side before rendering external anchors.

## Tooling
- Runs Vite directly through `node ./node_modules/vite/bin/vite.js` so zipped installs do not depend on fragile `.bin` wrappers.
