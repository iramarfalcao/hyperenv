# The HyperEnv site

A static, single-page site for distributing the app. Two files do the work —
`index.html` and `styles.css` — with no JavaScript, no build step, no
dependencies and no external requests. Upload the folder and it runs.

```
site/
├── index.html          the page
├── styles.css          the only stylesheet
├── robots.txt          crawl policy + sitemap pointer
├── sitemap.xml         one URL, since it is one page
├── site.webmanifest    name, icons, theme colour
├── install.sh          the one-command installer the page points at
├── _headers            caching + security headers (Netlify / Cloudflare Pages)
└── assets/
    ├── icon-256.png            the icon as the page shows it
    ├── icon-512.png            referenced by the manifest
    ├── apple-touch-icon.png    180px
    ├── favicon-32.png
    ├── screenshot-light.png    the app window, light appearance
    ├── screenshot-dark.png     the app window, dark appearance
    ├── step-new-project.png    the New Project sheet
    ├── step-new-profile.png    the New Profile sheet
    └── og-image.jpg            1200×630 social card
```

## Before publishing

**The domain is set to `https://hyperenv.falcaosl.com/`.** It appears in the
canonical link, the Open Graph and Twitter tags, the JSON-LD, `robots.txt` and
`sitemap.xml`. If the site ever moves, change all of them together:

```sh
grep -rl 'hyperenv.falcaosl.com' . \
  | xargs sed -i '' 's|https://hyperenv.falcaosl.com|https://new-domain|g'
```

Getting this wrong is not cosmetic. A canonical URL pointing at a domain you do
not control tells search engines to credit that domain instead of yours, and
social cards will fetch images from a host that does not have them.

Serve it over HTTPS at exactly that hostname. If both `www.` and the bare
hostname answer, redirect one to the other permanently — two hostnames serving
identical pages splits whatever ranking the page earns.

**The images are already here.** All of them are real captures of the app, taken
from a demo window holding invented data — no real environment variables, keys or
hostnames appear in any of them. Regenerate them at any time:

```sh
Scripts/capture-screenshots.sh          # light and dark, needs Screen Recording
Scripts/generate-social-card.sh         # the 1200×630 card
```

The hero uses `<picture>` to pick the light or dark capture by
`prefers-color-scheme`, so a visitor sees the one matching their system. If you
replace a capture at a different size, update the `width`/`height` on its `<img>`
— they reserve space so the page does not shift while loading.

**A video is optional and not shipped.** The walkthrough is three real
screenshots instead, which load instantly, carry alt text a search engine can
read, and cannot go out of date silently the way a recording does. If you want a
recording, drop an `.mp4` in `assets/` and swap it into the walkthrough
section.

**Check the version.** `softwareVersion` in the JSON-LD is written by hand. It is
the only place on the page that names a version, because every download link
resolves through GitHub's `releases/latest`.

## install.sh

The page offers one command:

```sh
curl -fsSL https://hyperenv.falcaosl.com/install.sh | bash
```

It must be served from the site's own domain, because that URL is printed in the
README, on the page, and anywhere else the project is written about. If the site
moves, that string moves with it.

`_headers` gives it a five-minute cache and a `text/plain` content type. Short,
because a script piped into a shell should be fixable quickly rather than sitting
in a CDN for a day; plain text, so it can be read in a browser rather than
downloaded as a file.

What it does: uses Homebrew if present, falls back to the disk image if not,
verifies the published SHA-256 **before** mounting anything, clears the
quarantine attribute, and never uses `sudo`. It refuses to install when the
checksum is missing, malformed or wrong — all three cases were tested against
the live release.

## The download links

They point at:

```
https://github.com/iramarfalcao/hyperenv/releases/latest/download/HyperEnv.dmg
https://github.com/iramarfalcao/hyperenv/releases/latest/download/HyperEnv.dmg.sha256
```

These never need editing. GitHub resolves `releases/latest/download/<name>` to
whatever the newest release holds, and the release workflow uploads an
unversioned copy under exactly these names alongside the versioned ones — which
is why the site can promise a current download without knowing the version.

## What is here for search

- One `<h1>`, a real heading hierarchy, and prose that answers the question
  someone would actually type rather than repeating a keyword.
- `SoftwareApplication` structured data, which is what produces an app-style
  rich result, plus `FAQPage`, which is where search engines lift answers from.
  Both are in a single `@graph`, so they are parsed as one connected description
  rather than three unrelated blocks.
- Canonical URL, Open Graph and Twitter card metadata.
- Explicit `width`/`height` on images and `fetchpriority` on the hero, so layout
  does not shift while loading — layout stability is a ranking signal, not only
  a courtesy.
- Real `<details>` elements for the FAQ: the answers are in the HTML whether or
  not they are open, so they are indexable.
- No JavaScript and no web fonts. Nothing blocks the first paint.

The FAQ answers on the page and the ones in the JSON-LD say the same thing on
purpose. Structured data that contradicts the visible page is treated as
spam, and rightly so.

## Local preview

```sh
python3 -m http.server 8000 --directory site
```

Then open <http://localhost:8000>. Use a server rather than opening the file
directly — `file://` breaks the manifest, the canonical link and the
relative asset paths in ways that will not happen in production.
