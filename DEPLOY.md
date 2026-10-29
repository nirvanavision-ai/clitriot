# Putting the prototype on clitriot.com

The `site/` folder is a ready-to-upload static site. It needs no build step and no server.

| File | Purpose |
|---|---|
| `index.html` | The whole prototype, self-contained (it loads fonts from Google Fonts) |
| `robots.txt` | Keeps search engines out while it's a prototype |
| `_headers` | Cloudflare Pages / Netlify headers: noindex, RTA adult label, no referrer |

## Recommended: Cloudflare Pages + Cloudflare Access

Cloudflare is free at this size. Its terms allow lawful adult sites, and it can password-protect the prototype so only people you invite can open it.

1. **Create a free Cloudflare account** at dash.cloudflare.com.
2. **Add the domain.** Choose *Add a site*, enter `clitriot.com`, and pick the Free plan. Cloudflare gives you two nameservers, for example `ada.ns.cloudflare.com`.
3. **Point the domain at Cloudflare.** Sign in at your registrar, open the DNS or nameserver settings for clitriot.com, and replace the nameservers with Cloudflare's two. This takes anywhere from a few minutes to a few hours to take effect.
4. **Upload the site.** Go to *Workers & Pages → Create → Pages → Upload assets*, name the project `clitriot`, and drag in the contents of the `site/` folder.
5. **Connect the domain.** In the Pages project, open *Custom domains* and add `clitriot.com` and `www.clitriot.com`. Cloudflare creates the DNS records and the HTTPS certificate on its own.
6. **Lock it (recommended).** Go to *Zero Trust → Access → Applications → Add → Self-hosted*, enter `clitriot.com`, and add a policy allowing specific emails (yours, investors, testers). Visitors then get a one-time code by email before the page loads.

To update the site later, upload the new `site/` contents to the same Pages project.

## clitriot.com is registered at Hostinger

Use the recommended route above. For step 3, on Hostinger:

1. Sign in to hPanel and open **Domains → clitriot.com**.
2. Open **DNS / Nameservers**, choose **Change nameservers**, then **Change nameservers manually** (not Hostinger's own).
3. Paste the two Cloudflare nameservers and save.

Before you switch, check Cloudflare's imported record list against Hostinger's DNS zone. If you use Hostinger email on this domain, its MX and TXT records must be in Cloudflare too, or email stops.

Hostinger's own DNS can't point the bare domain at Cloudflare Pages, which has no fixed IP address. That's why moving the nameservers is simpler than adding records at Hostinger.

## Hosting on Hostinger web hosting instead

1. In hPanel, open **Websites → clitriot.com → File manager** and go into `public_html`.
2. Delete Hostinger's placeholder `default.php` or `index.php` if there is one.
3. Upload `index.html`, `robots.txt` and `.htaccess` from the `site/` folder. (`.htaccess` is a hidden file; turn on "show hidden files" if you can't see it. `_headers` is for Cloudflare only and isn't needed here.)
4. Open **Security → SSL** and make sure the free SSL certificate is active for clitriot.com.
5. To keep the prototype private, open **Advanced → Password protect directories**, choose `public_html`, and set a username and password to share with investors.

To update the site, upload the new `index.html` over the old one.

## If the domain should stay at your registrar's DNS

Do steps 1 and 4 only. Then, at your registrar, add:

| Type | Name | Value |
|---|---|---|
| CNAME | `www` | `clitriot.pages.dev` |
| CNAME or ALIAS | `@` | `clitriot.pages.dev` (if the registrar can't do this for the root domain, forward `clitriot.com` to `https://www.clitriot.com`) |

Then add `www.clitriot.com` under *Custom domains* in the Pages project. Cloudflare Access (step 6) needs the domain on Cloudflare's nameservers.

## Before the real platform goes live

The prototype has no explicit content, so any static host can serve it. The production platform is different. Hosting, CDN, email and payments each need a provider that accepts adult content in writing, as the counsel packet already notes.
