// One GPU surface for the basemap; Leaflet continues to own route editing and
// cursor-anchored gestures. No per-tile DOM resizing occurs during zoom.
(function(){
 const sourceCache=new Map();
 async function imageryTile(url,signal){
  const cached=sourceCache.get(url);
  if(cached&&(cached.blob||Date.now()-cached.time<30000))return cached.blob;
  const controller=new AbortController(),abort=()=>controller.abort();
  signal.addEventListener('abort',abort,{once:true});
  if(signal.aborted)controller.abort();
  const timeout=setTimeout(abort,2500);
  try{
   const response=await fetch(url,{signal:controller.signal});
   if(!response.ok&&response.status!==404)throw new Error('Satellite tile: '+response.status);
   const blob=response.ok?await response.blob():null;
   sourceCache.delete(url);sourceCache.set(url,{blob,time:Date.now()});
   while(sourceCache.size>96)sourceCache.delete(sourceCache.keys().next().value);
   return blob;
  }catch(error){
   if(signal.aborted)throw error;
   // Missing high-level tiles can fail CORS or time out instead of returning
   // a readable 404. Continue to an ancestor in those cases as well.
   return null;
  }finally{clearTimeout(timeout);signal.removeEventListener('abort',abort);}
 }
 maplibregl.addProtocol('gpx-imagery',async(params,controller)=>{
  const [z,x,y]=params.url.slice('gpx-imagery://'.length).split('/').map(Number);
  for(let zoom=z;zoom>=Math.max(0,z-4);zoom--){
   if(controller.signal.aborted)throw new DOMException('Canceled','AbortError');
   const factor=2**(z-zoom),px=Math.floor(x/factor),py=Math.floor(y/factor);
   const url=`https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${zoom}/${py}/${px}?blankTile=false`;
   const blob=await imageryTile(url,controller.signal);
   if(!blob)continue;
   if(zoom===z)return {data:await blob.arrayBuffer()};
   const image=await createImageBitmap(blob),canvas=document.createElement('canvas');
   canvas.width=canvas.height=256;
   const context=canvas.getContext('2d');
   context.imageSmoothingQuality='high';
   context.drawImage(image,(x-px*factor)*image.width/factor,(y-py*factor)*image.height/factor,image.width/factor,image.height/factor,0,0,256,256);
   image.close();
   const cropped=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
   if(!cropped)throw new Error('Could not crop satellite tile');
   return {data:await cropped.arrayBuffer()};
  }
  throw new Error('Satellite imagery unavailable');
 });

 function basemapStyle(satellite){
  const style=JSON.parse(JSON.stringify(window.gpxVectorStyle));
  // Keep source definitions identical across styles so MapLibre's style diff
  // retains decoded vector tiles and the satellite source's tile cache.
  style.sources.imagery={type:'raster',tileSize:256,maxzoom:23,tiles:['gpx-imagery://{z}/{x}/{y}']};
  style.sources['imagery-preview']={type:'raster',tileSize:256,maxzoom:19,tiles:['gpx-imagery://{z}/{x}/{y}']};
  if(!satellite)return style;
  // Use crisp vector roads and labels over imagery, without raster overlay
  // tiles that can expose another grid or trigger duplicate image downloads.
  const overlays=style.layers.filter(layer=>
   layer.id.startsWith('boundary_')||layer.type==='symbol'||
   (layer.type==='line'&&/^(road_|bridge_|tunnel_)/.test(layer.id)));
  for(const layer of overlays){
   if(layer.type==='line'&&!layer.id.startsWith('boundary_'))layer.maxzoom=17;
   if(layer.type==='symbol'&&layer.layout?.['text-field']){
    layer.paint={...layer.paint,'text-color':'#ffffff','text-halo-color':'#333333','text-halo-width':1.2};
   }
  }
  style.layers=[{id:'background',type:'background',paint:{'background-color':'#dddcd7'}},
   {id:'satellite-preview',type:'raster',source:'imagery-preview',paint:{'raster-fade-duration':0,'raster-resampling':'linear'}},
   {id:'satellite',type:'raster',source:'imagery',paint:{'raster-fade-duration':0,'raster-resampling':'linear'}},...overlays];
  return style;
 }

 const GPUBasemap=L.MaplibreGL.extend({
  onAdd:function(target){
   // Initialize through the renderer's public constructor. The adapter's
   // private transform mutations can leave cold, deeply zoomed views waiting
   // for a movement before tile selection is refreshed.
   if(!this._container)this._initContainer();
   target.getPane(this.getPaneName()).appendChild(this._container);
   const center=target.getCenter();
   this._glMap=new maplibregl.Map({...this.options,container:this._container,
    center:[center.lng,center.lat],zoom:target.getZoom()-1,attributionControl:false});
   this._glMap.on('style.load',()=>{this._resizeGPU();this._glMap?.triggerRepaint();});
   this._visibilityHandler=()=>{
    if(!document.hidden){this._resizeGPU();this._glMap?.triggerRepaint();}
   };
   document.addEventListener('visibilitychange',this._visibilityHandler);
   this._sync();this._glMap.triggerRepaint();
  },
  onRemove:function(target){
   document.removeEventListener('visibilitychange',this._visibilityHandler);
   L.MaplibreGL.prototype.onRemove.call(this,target);
  },
  setSatellite:function(satellite){
   if(this._satellite!==satellite){
    this._satellite=satellite;
    this._glMap.setStyle(basemapStyle(satellite),{diff:true});
    this.options.attribution=basemapAttribution(satellite);
    if(this._map.attributionControl){
     this._map.attributionControl.removeAttribution(basemapAttribution(!satellite));
     this._map.attributionControl.addAttribution(this.options.attribution);
    }
   }
   this._sync();this._glMap.triggerRepaint();
  },
  getEvents:function(){return {move:this._sync,resize:this._resizeGPU};},
  _sync:function(){
   if(!this._map||!this._glMap)return;
   const offset=this._map.getSize().multiplyBy(this.options.padding);
   L.DomUtil.setPosition(this._container,this._map.containerPointToLayerPoint([0,0]).subtract(offset));
   const center=this._map.getCenter();
   this._glMap.jumpTo({center:[center.lng,center.lat],zoom:this._map.getZoom()-1,bearing:0,pitch:0});
  },
  _resizeGPU:function(){
   if(!this._map||!this._glMap)return;
   const size=this.getSize();
   this._container.style.width=size.x+'px';this._container.style.height=size.y+'px';
   this._glMap.resize();this._sync();
  }
 });
 function basemapAttribution(satellite){
  return '<a href="https://openfreemap.org/">OpenFreeMap</a> © <a href="https://openmaptiles.org/">OpenMapTiles</a> © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'+
   (satellite?' · Imagery: Esri, Vantor, Earthstar Geographics, and the GIS User Community':'');
 }
 window.installGPUBasemap=function(target,satellite){
  const attribution=basemapAttribution(satellite);
  const layer=new GPUBasemap({style:basemapStyle(satellite),interactive:false,padding:0.1,attribution,
   maxZoom:23,minZoom:0,pitch:0,bearing:0,renderWorldCopies:true,fadeDuration:0,maxTileCacheSize:128,
   cancelPendingTileRequestsWhileZooming:true});
  layer._satellite=satellite;
  layer.addTo(target);
  target._gpxBasemap=layer;
  return layer;
 };
})();
