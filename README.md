# Portal for iPhone

The whole of home.hellupeptic.org in an app, plus Chromecast casting to
whatever TVs are on the Wi-Fi the phone is on (something a website on an
iPhone can't do).

- `Portal/Web/WebViewController.swift`: the site in a `WKWebView`, with native
  `confirm()`/`prompt()` dialogs, downloads to the share sheet, other sites in
  an in-app browser, and a notice before the free signature runs out or when
  a new version is out.
- `Portal/Cast/CastBridge.swift`: the `portalCast` message handler the Vault
  page talks to (`window.webkit.messageHandlers.portalCast.postMessage`),
  built on Google's Cast SDK and the Default Media Receiver. The site hands it
  tokened links from `/api/cast/link`.

## Building and installing (no Mac, nothing paid)

Every push to `main` builds an unsigned `.ipa` on GitHub Actions (free macOS
runners). The Pi downloads the artifact and publishes it at
`home.hellupeptic.org/app`, which serves a SideStore source. SideStore signs
the app with a free Apple ID on the phone, and renews it every 7 days.

The Xcode project is generated from `project.yml` with XcodeGen, so there's
no `.xcodeproj` in the repo.
