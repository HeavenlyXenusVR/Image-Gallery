# Nyxframe

![Witch Knot site icon](favicon.ico)

Nyxframe is the React and FastAPI media site for uploaded images, GIFs, wallpapers, profile pictures, memes, and videos. It is built around a MySQL-backed account system, local or tunnel-backed media delivery, AI-assisted tagging, and social profile discovery.

## What It Does

- Uploads and serves images, GIFs, and videos with thumbnail, preview, and quality variants.
- Keeps video playback inside the React app without background refreshes interrupting the player.
- Provides protected media controls: copy media address, copy post link, open original, and download when allowed.
- Blocks browser right-click menus across the app to reduce casual saving of uploaded media.
- Uses age verification gates for 18+ posts and replaces the verification form with a verified state after approval.
- Supports public user profiles with avatars, display names, bios, links, profile colors, cover styling, privacy, and online or inactive presence.
- Lets users browse other profiles, follow creators, send friend requests, message accounts, save media, and build collections.
- Uses AI-assisted upload analysis for categories, tags, character hints, franchise hints, adult-safety checks, and smarter search metadata.
- Generates real thumbnails for uploaded videos from the source file instead of showing a generic placeholder.
- Stores gallery settings, profile customization, social data, media metadata, reports, and account state in the `image_gallery` schema.
- Publishes a static GitHub Pages frontend that reads `live-config.json` for the current live backend URL.

## Main Surfaces

- **Gallery Feed:** fast browsing, filters, reactions, media actions, locked previews, and responsive card layouts.
- **Media Detail:** large media viewer, comments, collections, direct address tools, related metadata, and stable video playback.
- **Profiles:** avatar, presence, bio, customization, uploads, social actions, and public account details.
- **Creator Studio:** upload history, media stats, owner actions, visibility controls, and deletion.
- **Settings:** theme, accent, density, media behavior, age state, profile customization, and account preferences.
- **Admin and Health:** health route, request tracing, storage reporting, Telegram operator alerts, and backend diagnostics.

## Servers And Data

- Frontend: React and Vite, deployable to GitHub Pages.
- Backend: FastAPI app served from `app.main`.
- Database: MySQL schema `image_gallery`.
- Media storage: local filesystem by default, with app-level storage abstractions.
- Optional AI: Ollama, Gemini, or OpenAI-compatible vision providers.
- Operator alerts: Telegram bridge for scoped health and database notices.

## Guardrails

- Secrets belong in ignored environment files, never in committed code.
- Media route responses include security and cache headers.
- Right-click is disabled in-app, but this should be treated as a deterrent rather than DRM.
- AI character recognition uses local guide hints as suggestions, not proof.
- Age-gated content stays hidden until the account is verified.

## Copyright

(c) HeavenlyXenusVR. Discord: <https://discord.com/users/1304564041863266347>
