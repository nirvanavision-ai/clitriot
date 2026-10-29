# Clitriot

Clickable prototype of Clitriot, a mobile-first vertical video platform for the adult creator economy built on a prepaid wallet and per-scene micro-transactions.

**The prototype contains no explicit content.** Every video is an abstract animated placeholder, and all money is simulated in the browser.

## What's in it

- **Viewer:** age gate and fail-closed region routing, a swipe feed with 6-second free previews, a prepaid wallet with FIFO deposit lots and a first-deposit starter, linear and branching series with labeled/teased/blind doors, bundles, spend-gated messaging with paid messages, and silent block and mute.
- **Creator:** earnings with the revenue split snapshotted on every sale, door and path analytics, a "before you film" compliance checklist, and a message minimum.
- **Admin:** effective-dated revenue splits (raises apply now, cuts need 30 days' notice), pricing tiers, and jurisdiction routing.

## Layout

| Path | What it is |
|---|---|
| `index.html` | The whole prototype in one self-contained file (served at clitriot.com) |
| `robots.txt`, `.htaccess`, `_headers` | Keep it out of search engines, force HTTPS, label it as adult |
| `docs/DEPLOY.md` | How pushes to `main` auto-deploy to Hostinger |

## Run locally

Open `index.html` in a browser, or run `npx serve .`

Pushes to `main` deploy to clitriot.com automatically (see `docs/DEPLOY.md`).
