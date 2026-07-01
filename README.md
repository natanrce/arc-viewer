<p align="center">
  <a href="https://github.com/natanrce/arc-viewer" target="blank">
    <img src="https://github.com/natanrce/arc-viewer/blob/main/Arc%20Viewer/Resources/Assets.xcassets/AppIcon.appiconset/Icon-iOS-Default-1024x1024@1x.png" width="120" alt="Logo" />
  </a>
</p>

<p align="center">
  <p align="center">
   Arc Viewer
  </p>
</p>

<p align="center">
  <a href="https://github.com/fastwa/fastwa" target="_blank">
    <img src="https://img.shields.io/github/stars/natanrce/arc-viewer" alt="Stargazers" />
  </a>
  <a href="https://github.com/fastwa/fastwa" target="_blank">
    <img src="https://img.shields.io/github/issues/natanrce/arc-viewer" alt="Issues" />
  </a>
</p>

## Philosophy

Inspect and explore [Arc Browser](https://arc.net/) cache, Local Storage, IndexedDB, cookies, browsing history, and other browser artifacts on macOS (Apple Silicon). Arc Viewer is designed to simplify the analysis of browser data for security audits, digital forensics, incident response, web application debugging, and recovering cached copies of pages or resources that are no longer available online.

### Constraints

Browser caching depends directly on the `Cache-Control` response header returned by the server. This header determines whether a page or resource can be stored locally and, consequently, whether Arc Viewer will be able to inspect it. If the server disables caching, the resource will not be present in the browser cache.

When preserving cached responses is desirable, this limitation can be bypassed by adding or overriding missing `Cache-Control` response headers before the browser processes the response (e.g., [Speed-Up Browsing OG](https://chromewebstore.google.com/detail/speed-up-browsing-og/knanacnclidfnjffodfhnnpkeflicaoh)).

## Compatibility

The application is compatible with Chromium-based browsers that use the same storage format as Arc Browser. However, only the following environment has been officially validated.

| Component | Version | Status |
|-----------|---------|--------|
| Arc Browser | **1.153.1 (82775)** | ✅ Tested |
| Chromium-based browsers | Compatible in theory* | ⚠️ Not tested |
| macOS | **26.5 (25F71)** | ✅ Tested |

## Stay in touch

* Author - [Natan Rodrigues](https://github.com/natanrce)
* Website - [natanz.in](https://natanz.in)
* E-mail - [natanrce@proton.me](mailto:natanrce@proton.me)

## License

Distributed under the MIT License. See [LICENSE](https://github.com/natanrce/arc-viewer/blob/main/LICENSE) for more information.
