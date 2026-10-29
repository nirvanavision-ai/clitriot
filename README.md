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
| `site/index.html` | The whole prototype in one self-contained file |
| `site/robots.txt`, `site/_headers` | Keep it out of search engines and label it as adult |
| `DEPLOY.md` | How to serve `site/` at clitriot.com with Cloudflare Pages |

## Run locally

Open `site/index.html` in a browser, or serve the folder:

```sh
npx serve site
```
