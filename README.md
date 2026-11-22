# GPX Creator

Native SwiftUI macOS app (macOS 14 or newer).

Double-click **GPX Creator.app**, or run `./build.sh` to rebuild it. Open `Package.swift` in Xcode to edit the project. Run `swift test` for parsing and interpolation checks.

The build script automatically uses Brian's local Apple Development certificate when available, keeping the app's signing identity stable across rebuilds for Keychain access. On other machines it uses ad-hoc signing, with no developer certificate or account required. Override signing with `GPX_SIGNING_IDENTITY="Your signing identity" ./build.sh`, or force ad-hoc signing with `GPX_SIGNING_IDENTITY=- ./build.sh`. An explicitly selected certificate must sign successfully; signing failures stop the build.

Switching from the old ad-hoc build to a development-signed build may require one more Keychain approval (choose **Always Allow** when macOS asks). Subsequent builds signed with the same identity should retain that approval. macOS may also request permission for `codesign` to use the certificate's private key the first time. Running directly from Xcode uses Xcode's own signing settings; use `./build.sh` for this signing workflow.

- The left rail switches between Creator and Dashboard. Settings accepts a Google Maps key in a secure field and stores it in macOS Keychain.
- Dashboard imports GPX coordinates into Application Support/GPXCreator/tracks.json. Original files are never modified or removed. Its map layers button switches between OpenStreetMap and Google Maps; the selection is saved. Drag the divider to resize the persistent sidebar. Selecting a list entry fits the map with a 20% geographic buffer.
- Creator references selected GPX and video files without copying them. Route anchors, fill mode, finished state, and video playback position are saved and restored. Open the controls sidebar at the upper right to set the GPX sample rate or export.
- Scrub and click the map to create timestamped anchors. Drag anchors, right-click to remove, click the line to insert, and double-click an anchor to edit its coordinates. The checkered flag marks only an anchor at the video's end. Generated points interpolate between anchors at the configured samples per second, defaulting to 200.
- Hover the path to preview the corresponding video moment. Hover the timeline for a thumbnail and a map cursor.
- OpenStreetMap uses OpenFreeMap vector tiles with a flat Liberty style, rendered by MapLibre GL beneath the Leaflet editing overlays. Vector geometry, buildings, roads, and labels remain sharp through zoom level 24. OpenStreetMap Satellite uses GPU-rendered Esri imagery with vector roads and labels; imagery requests native tiles through level 23 and reuses them above that level and falls back to matching parent imagery where coverage is missing. Google Maps uses the JavaScript API and its StreetViewCoverageLayer. Network access is required. Coverage visibility and content depend on Google’s response for the supplied key. The API exposes a combined coverage layer, not separate line/photo controls.
- Equirectangular video is displayed as the full flat frame with AVPlayer. Codec support follows AVFoundation. GPX export uses the current date as the timestamp origin plus each anchor’s video offset.

The key is not redisplayed by Settings; it must be supplied to Google's JavaScript runtime to authenticate map requests. API keys used by browser maps are accessible to that runtime.

Run `node scripts/test-map-tiles.cjs` for basemap configuration, camera synchronization, imagery fallback, caching, and cancellation checks. Bundled renderer versions and licenses are listed in `Sources/GPXCreator/Resources/vendor/README.md`.

### Video Tools

The left Video Tools tab references a selected video in place. Export FPS defaults to 2 and is saved across launches, along with destination preferences. It shows the source size and an approximate export size, and calculates meters or feet between frames from m/s, ft/s, or mph.

Exports use FFmpeg and ffprobe from Contents/Helpers, /opt/homebrew/bin, or /usr/local/bin. Apple Silicon tries VideoToolbox first for supported 8/10-bit formats, falling back to software encoding if encoding or metadata preservation checks fail. Other streams are copied. Exports preserve resolution and bit depth and check source tags, color metadata, side metadata, and chapters; unsupported preservation causes an error. Encoder/container bookkeeping is regenerated. Output is fully decoded before the temporary file is moved to its final path. Existing files and the source cannot be overwritten. Size estimates are approximate, especially with software encoding.

Video Tools supports multiple referenced videos and a shared, sequential export queue. Select a video to edit its next export, then Export selected video or Export all. Each queued request snapshots its settings; later edits do not affect it. Repeated exports get distinct filenames. New imports inherit the last video's compatible settings, with custom output folders transferred to a new filename. The queue estimates total remaining time using observed export speed; estimates are approximate and depend on media format, resolution, and encoder fallback. X cancels an active or waiting export. Quit confirmation cancels waiting work and waits for temporary-file cleanup. MP4 HEVC exports use hvc1 and are checked with the native macOS decoder before saving.
