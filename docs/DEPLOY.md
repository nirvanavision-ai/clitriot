# Deploying clitriot.com

The site is the repo root: `index.html`, `robots.txt`, `.htaccess` (and `_headers`, used only if the site ever moves to Cloudflare Pages or Netlify). There is no build step.

## Automatic deploys from GitHub to Hostinger

After this one-time setup, every push to `main` updates clitriot.com within a minute.

1. **Empty the site folder.** In hPanel, open **Websites → clitriot.com → File manager → public_html** and delete everything in it, including hidden files. Hostinger only deploys into an empty folder.
2. **Get Hostinger's deploy key.** In hPanel, open **Advanced → Git**. Copy the **SSH key** shown there.
3. **Give that key read access to the repo.** On GitHub, open the clitriot repo → **Settings → Deploy keys → Add deploy key**. Title it `Hostinger`, paste the key, leave "Allow write access" off, and save.
4. **Create the repository link.** Back in hPanel → **Git → Create a new repository**:
   - Repository: `git@github.com:nirvanavision-ai/clitriot.git`
   - Branch: `main`
   - Directory: leave empty (deploys into `public_html`)
   
   Click **Create**, then **Deploy**.
5. **Turn on auto-deploy.** In the repository row in hPanel, click **Auto deployment** and copy the **webhook URL**. On GitHub, open **Settings → Webhooks → Add webhook**, paste it as the Payload URL, keep "Just the push event", and save.
6. **Check it.** Open https://clitriot.com. You should see the Clitriot age gate.

From then on, a change merged to `main` is live after the webhook fires. To redeploy by hand, click **Deploy** in hPanel → Git.

## Keep it private (recommended)

hPanel → **Advanced → Password protect directories** → `public_html`. Share the username and password only with people who should see the prototype. This survives redeploys because it lives outside the repo.

## HTTPS

hPanel → **Security → SSL** should show an active certificate for clitriot.com. `.htaccess` sends all http traffic to https.

## Before the real platform launches

The prototype has no explicit content. Before real content goes live, confirm in writing that Hostinger (or whichever host and CDN you choose) accepts lawful adult content.
