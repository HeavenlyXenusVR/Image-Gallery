# Gemini Analyze Routing Patch

This patch fixes the Image Gallery analyze path so Gemini is the first-class vision provider.

## Root causes found

- `.env` selected `GALLERY_AI_PROVIDER=gemini`, but `GALLERY_OLLAMA_BASE_URL` and `GALLERY_OLLAMA_MODEL` were also present. Some fallback/source-label logic could still treat Ollama as active or label results as Ollama.
- Gemini failures were placed into a cooldown/backoff path that could cause later Analyze clicks to use local fallback instead of trying Gemini again.
- The source label code checked `GALLERY_OLLAMA_MODEL` before Gemini and could label a Gemini-selected setup as `ollama`.
- The uploaded zip does not contain a Gemini API key. The app now reports that clearly instead of silently looking like it used another provider.

## Behavior after patch

- If `GALLERY_AI_PROVIDER=gemini`, analyze uses Gemini and does not route to Ollama/OpenAI because Ollama variables exist.
- Gemini API keys are read from `GALLERY_GEMINI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`, including optional `_FILE` variants.
- Gemini model is read from `GALLERY_GEMINI_MODEL` or `GEMINI_MODEL`, defaulting to `gemini-2.5-flash-lite`.
- Gemini backoff is disabled by default with `GALLERY_GEMINI_BACKOFF_ENABLED=false`, so one temporary Gemini failure will not make later Analyze clicks silently use local fallback for 10 minutes.
- Analyze output now tags successful Gemini results as `google-gemini`.
- `/api/ai/vision/status` now shows whether a Gemini key is configured without exposing the secret.
