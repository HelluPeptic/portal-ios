# Peptic's Workshop for iPhone

The whole of home.hellupeptic.org in an app, plus Chromecast casting to
whatever TVs are on the Wi-Fi the phone is on (something a website on an
iPhone can't do), and Vault movies and episodes saved on the phone to watch
without a connection. It was called Portal at first, which is still its name
in the code and its bundle ID (changing that would make it a different app
to SideStore).

- `Portal/Web/WebViewController.swift`: the site in a `WKWebView`, with native
  `confirm()`/`prompt()` dialogs, downloads to the share sheet, other sites in
  an in-app browser, and a notice before the free signature runs out or when
  a new version is out.
- `Portal/Cast/CastBridge.swift`: the `portalCast` message handler the Vault
  page talks to (`window.webkit.messageHandlers.portalCast.postMessage`),
  built on Google's Cast SDK and the Default Media Receiver. The site hands it
  tokened links from `/api/cast/link`.
- `Portal/Offline/`: downloads. `OfflineBridge` is the `portalDownloads`
  handler the Vault talks to; `OfflineStore` downloads in a background
  `URLSession` (it carries on with the app closed) from tokened links the
  site makes (`/api/vault/download-link`); `DownloadsViewController` is the
  list, also offered on the "Can't reach the site" screen; `OfflinePlayback`
  plays one in the system player, drawing its WebVTT subtitles itself and
  keeping where it was left, which the site picks up later (spa-shell.js).

## Building and installing (no Mac, nothing paid)

Every push to `main` builds an unsigned `.ipa` on GitHub Actions (free macOS
runners). The Pi downloads the artifact and publishes it at
`home.hellupeptic.org/app`, which serves a SideStore source. SideStore signs
the app with a free Apple ID on the phone, and renews it every 7 days.

To publish the newest successful build on the Pi:

    ./publish.sh

The Xcode project is generated from `project.yml` with XcodeGen, so there's
no `.xcodeproj` in the repo.
