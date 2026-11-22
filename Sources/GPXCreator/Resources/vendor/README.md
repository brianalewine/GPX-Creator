Bundled map dependencies

- Leaflet 1.9.4: https://leafletjs.com/ (leaflet.js; leaflet-LICENSE.txt)
- MapLibre GL JS 5.24.1: https://maplibre.org/ (maplibre-gl.js, maplibre-gl.css; maplibre-LICENSE.txt)
- MapLibre GL Leaflet 0.1.0: https://github.com/maplibre/maplibre-gl-leaflet (leaflet-maplibre-gl.js; leaflet-maplibre-LICENSE.txt)
- OpenFreeMap Liberty style: https://tiles.openfreemap.org/styles/liberty and https://github.com/hyperknot/openfreemap-styles (../vector-style.js; openfreemap-styles-LICENSE.md)

The style was adapted to retain flat building footprints through zoom level 24 and stop repeated road-arrow icons at extreme zoom levels. Satellite uses vector labels over Esri World Imagery. Map data, fonts, sprites, and imagery remain online resources; Leaflet and the GPU renderer scripts are bundled locally.
