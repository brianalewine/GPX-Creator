# GPX Creator

Native SwiftUI macOS app (macOS 14 or newer).

Double-click **GPX Creator.app**, or run `./build.sh` to rebuild it. Open `Package.swift` in Xcode to edit the project. Run `swift test` for parsing and interpolation checks.

- The left rail switches between Creator and Dashboard. Settings accepts a Google Maps key in a secure field and stores it in macOS Keychain.
- Dashboard imports GPX coordinates into Application Support/GPXCreator/tracks.json. Original files are never modified or removed. Drag the divider to resize the persistent sidebar. Selecting a list entry fits the map with a 20% geographic buffer.
- Creator references selected GPX and video files without copying them. These editing sessions are currently in memory. Open the controls sidebar at the upper right to generate points or export.
- Scrub and click the map to create timestamped anchors. Drag anchors, right-click to remove, click the line to insert, double-click to finish, and click the finish flag to extend. Generated points interpolate between anchors at whole video seconds and recalculate when anchors change.
- Hover the path to preview the corresponding video moment. Hover the timeline for a thumbnail and a map cursor.
- OpenStreetMap uses Leaflet and online OSM tiles. Google Maps uses the JavaScript API and its StreetViewCoverageLayer. Network access is required. Coverage visibility and content depend on Google's response for the supplied key. The API exposes a combined coverage layer, not separate line/photo controls.
- Equirectangular video is displayed as the full flat frame with AVPlayer. Codec support follows AVFoundation. GPX export uses the current date as the timestamp origin plus each anchor’s video offset.

The key is not redisplayed by Settings; it must be supplied to Google's JavaScript runtime to authenticate map requests. API keys used by browser maps are accessible to that runtime.
