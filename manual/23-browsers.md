# Browsers

Omarchy ships with [Firefox](https://www.firefox.com/) as the default browser. It's what `Super + Shift + Return` opens, and it comes set up so Google isn't in the loop: DuckDuckGo is the search engine and Google is removed from the search list, telemetry and studies are off, Google Safe Browsing is off, location lookups go to [BeaconDB](https://beacondb.net/) instead of Google, and DRM video (Widevine, which Firefox downloads from Google) stays off until a site asks for it and you say yes.

If Firefox isn't your taste, you're not stuck with it. Under _Install > Browser_ in the Omarchy menu you'll find Chromium, Chrome, Edge, Brave, Brave Origin, and [Zen](https://zen-browser.app/). Pick one and Omarchy installs it, sets up its policy directory, and applies your current theme to it. Chromium also gets a policy that turns off the Google services it would otherwise call on its own (Safe Browsing, usage reports, translation, the online spelling service, password leak checks and error-page suggestions). Chrome, Edge and Brave stay as their makers ship them, since picking one means picking its services. Chromium's search engine is still Google until you change it in its settings.

## Making one the default

Installing a browser doesn't promote it. Once it's on the machine, go to _Setup > Defaults > Browser_ and pick it — the menu only lists browsers you actually have installed, and marks the current default with a check.

From the terminal it's:

```bash
omarchy default browser firefox
```

Run it with no argument and it tells you the current default. This sets the XDG handler, so it's not just Omarchy's hotkeys that follow along — anything that opens a link, from a chat app to a terminal command, goes to the browser you picked.

## Copy URL and Download Video

The Chromium-family browsers (Chromium itself, Chrome, Edge, and Brave) come with two Omarchy extensions that reach out of the browser and into the rest of your system.

**Copy URL** puts the current tab's address on your clipboard with `Alt + Shift + L`. That's faster than clicking into the address bar and copying, and because it goes through the system clipboard rather than the browser's, you get an Omarchy notification confirming it and the URL is immediately available in [clipboard history](08-unified-clipboard-history.md) and every other app. There's a toolbar button too, if you prefer clicking.

**Download Video** grabs the video playing on the page you're looking at with `Alt + Shift + D`. It hands the URL to [yt-dlp](https://github.com/yt-dlp/yt-dlp), so it works on far more than YouTube, and the download lands in `~/Videos`. Progress shows up in the same on-screen display that volume and brightness use, updating in place rather than stacking up notifications. Set `OMARCHY_YTDLP_DIR` if you'd rather the files went somewhere else — see the [FAQ](46-faq.md) for where to put environment variables.

Both extensions talk to Omarchy through a small native messaging host, which gets installed for you along with the browser. That's the piece that lets a web page's video end up in your home directory and a URL end up in your clipboard manager, which a normal extension can't do on its own.

These are Chromium-family only. Firefox and Zen don't get them.

## Firefox and Zen

Firefox and Zen are a different family, so they get different treatment: Omarchy installs a policies file (`/usr/lib/firefox/distribution/policies.json`) with the privacy defaults above and native Wayland settings for fractional scaling and smooth trackpad scrolling. The search, Safe Browsing, location and DRM settings are defaults rather than locks, so you can change them in Settings or `about:config`; telemetry and studies stay off.

They don't get the Chromium extensions above, and they're not themed by Omarchy, so those parts of the experience are yours to set up.

## Web apps without Chromium

[Web apps](25-web-apps.md) run as their own app windows inside a Chromium-family browser. With only Firefox installed, a web app opens in a new Firefox window instead. Install Chromium (or another Chromium-family browser) if you want the separate app windows back.

## Removing one again

Anything you installed here can be taken back off under _Remove > Browser_, Firefox included. If you remove the browser that's currently the default, Firefox takes over again, or Chromium when Firefox is the one going.
