const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.join(__dirname,'../Sources/GPXCreator/Resources');
new vm.Script(fs.readFileSync(path.join(root,'map.html'),'utf8').match(/<script>([\s\S]*)<\/script>/)[1]);
let protocol,definition,requests=[],crop;
class Layer {constructor(options){this.options=options;}addTo(){return this;}}
const context={window:{},setTimeout,clearTimeout,AbortController,DOMException,Date,
 maplibregl:{addProtocol:(_,handler)=>protocol=handler},
 L:{MaplibreGL:{extend:methods=>{definition=methods;Object.assign(Layer.prototype,methods);return Layer;}},DomUtil:{setPosition(){}}},
 fetch:async url=>{requests.push(url);const missing=url.includes('/19/');return {ok:!missing,status:missing?404:200,blob:async()=>new Blob(['image'])};},
 createImageBitmap:async()=>({width:256,height:256,close(){}}),
 document:{addEventListener(){},removeEventListener(){},createElement:()=>({getContext:()=>({drawImage(...args){crop=args.slice(1);}}),toBlob:callback=>callback(new Blob(['cropped']))})}
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(root,'vector-style.js'),'utf8'),context);
vm.runInContext(fs.readFileSync(path.join(root,'gpu-basemap.js'),'utf8'),context);
(async()=>{
 const map={};const flat=context.window.installGPUBasemap(map,false);
 assert.equal(map._gpxBasemap,flat);
 assert.equal(flat.options.maxZoom,23,'Leaflet zoom 24 corresponds to GL zoom 23');
 assert(!flat.options.style.layers.some(l=>l.type==='fill-extrusion'));
 assert.equal(flat.options.style.layers.find(l=>l.id==='building').maxzoom,undefined);
 const satellite=context.window.installGPUBasemap(map,true);
 assert.equal(satellite.options.style.sources.imagery.maxzoom,23);
 assert.equal(satellite.options.style.sources['imagery-preview'].maxzoom,19);
 assert(satellite.options.style.layers.findIndex(l=>l.id==='satellite-preview')<satellite.options.style.layers.findIndex(l=>l.id==='satellite'),'preview imagery must render beneath full detail');
 assert.equal(satellite.options.style.layers.find(l=>l.id==='satellite').paint['raster-fade-duration'],0);
 assert(!satellite.options.style.layers.some(l=>l.type==='fill-extrusion'));
 assert(Object.values(satellite.options.style.sources).some(s=>s.type==='vector'));
 let move;
 satellite._map={getSize:()=>({multiplyBy:()=>({})}),containerPointToLayerPoint:()=>({subtract:()=>({})}),getCenter:()=>({lat:42,lng:-71}),getZoom:()=>24};
 satellite._container={};satellite._glMap={jumpTo:camera=>move=camera};definition._sync.call(satellite);
 assert.equal(move.zoom,23);assert.equal(move.pitch,0);assert.equal(move.bearing,0);
 assert.deepEqual(Array.from(move.center),[-71,42]);
 assert.deepEqual(Object.keys(definition.getEvents()).sort(),['move','resize'],'one basemap update per Leaflet movement, without duplicate zoom updates');
 const gpu=satellite._glMap,styles=[],ready={};let repaints=0,resizes=0;
 Object.assign(gpu,{on:(name,handler)=>ready[name]=handler,triggerRepaint:()=>repaints++,resize:()=>resizes++,setStyle:(style,options)=>styles.push({style,options})});
 const target=satellite._map;
 satellite.getSize=()=>({x:100,y:100});satellite._container.style={};
 context.maplibregl.Map=function(options){assert.equal(options.zoom,23);return gpu;};
 satellite.getPaneName=()=> 'tilePane';target.getPane=()=>({appendChild(){}});
 definition.onAdd.call(satellite,target);
 assert.equal(repaints,1,'initializing a basemap must request rendering without a pan');
 ready['style.load']();
 assert.equal(resizes,1,'style readiness must synchronize the viewport without a pan');
 assert.equal(repaints,2);
 satellite.setSatellite(false);
 assert.equal(satellite._glMap,gpu,'switching modes must reuse the GPU renderer');
 assert.equal(satellite._map,target,'switching modes must retain the map and camera');
 assert.equal(styles[0].options.diff,true);
 assert.equal(JSON.stringify(styles[0].style.sources),JSON.stringify(satellite.options.style.sources),'style switches must retain identical tile source definitions');
 satellite.setSatellite(false);
 assert.equal(styles.length,1,'selecting the current mode must not reload its style');
 satellite.setSatellite(true);
 assert.equal(styles.length,2);
 const mapHTML=fs.readFileSync(path.join(root,'map.html'),'utf8');
 let mode;
 const reusedMap={_gpxBasemap:{setSatellite:value=>mode=value}};
 const switching={map:reusedMap,provider:'osm'};
 vm.createContext(switching);
 vm.runInContext(mapHTML.slice(mapHTML.indexOf('async function setup('),mapHTML.indexOf('let clickTimer,')),switching);
 await switching.setup({google:false,osmSatellite:true});
 assert.equal(mode,true);assert.equal(switching.map,reusedMap);assert.equal(switching.provider,'esri');
 await switching.setup({google:false,osmSatellite:false});
 assert.equal(mode,false);assert.equal(switching.map,reusedMap);assert.equal(switching.provider,'osm');
 const detailed=await protocol({url:'gpx-imagery://23/12345/67890'},new AbortController());
 assert.equal(Buffer.from(detailed.data).toString(),'image','available high-resolution imagery must be returned directly, without scaling a parent');
 assert(requests.at(-1).includes('/tile/23/67890/12345?blankTile=false'),'deep zoom must request level 23 imagery');
 const result=await protocol({url:'gpx-imagery://19/12345/67890'},new AbortController());
 assert.equal(Buffer.from(result.data).toString(),'cropped');
 assert.deepEqual(crop,[128,0,128,128,0,0,256,256]);
 const count=requests.length;
 await protocol({url:'gpx-imagery://19/12345/67890'},new AbortController());
 assert.equal(requests.length,count,'cached successful and missing tiles should avoid repeat requests');
 const originalFetch=context.fetch;
 context.fetch=async(url,options)=>{if(url.includes('/23/'))throw new TypeError('Load failed');return originalFetch(url,options);};
 const corsFallback=await protocol({url:'gpx-imagery://23/10/10'},new AbortController());
 assert.equal(Buffer.from(corsFallback.data).toString(),'cropped','network/CORS failures must fall back to an ancestor too');
 context.fetch=originalFetch;
 const canceled=new AbortController();canceled.abort();
 await assert.rejects(protocol({url:'gpx-imagery://19/0/0'},canceled),{name:'AbortError'});
 console.log('PASS: script syntax, sharp vector overzoom, flat buildings, GPU style switching without map recreation, rendering on style readiness, camera synchronization, ancestor cropping/cache, and cancellation.');
})().catch(error=>{console.error(error);process.exitCode=1;});
