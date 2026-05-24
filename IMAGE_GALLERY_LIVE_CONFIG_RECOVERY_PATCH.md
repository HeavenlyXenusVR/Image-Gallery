# Image Gallery live-config/login recovery patch

- Repaired invalid `live-config.json` by removing the stray hash line that made the static React app lose its backend origin.
- Bumped frontend API cache version to v5 so browsers stop using stale bad API origins.
- Made React `live-config.json` loading tolerate accidental garbage and salvage the API URL/local fallback list.
- Lets remote/static-mode auth POSTs (`/api/auth/login`, `/api/auth/register`, `/api/auth/resend-verification`) refresh the live backend origin after 404/405/5xx tunnel responses.
- Validates `live-config.json` before live scripts publish it to GitHub Pages.
- Adds health-check timeout protection in live scripts.
