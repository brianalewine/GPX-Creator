(async()=>{
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
class InputEvent {constructor(type,options){this.type=type;Object.assign(this,options);}}
const ctx={Math,WeakSet,PointerEvent:InputEvent,MouseEvent:InputEvent,setTimeout:()=>1,clearTimeout(){},lastPointer3D:{},disposeZoom(){},document:{addEventListener(){},removeEventListener(){},getElementById:()=>({clientHeight:800})}};
vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('function mapViewportHeight'),html.indexOf('function currentCamera')),ctx);
vm.runInContext(html.slice(html.indexOf('function installGoogle3DGestures'),html.indexOf('function updateDraggedPath')),ctx);
for(const lat of [0,42,75])for(const zoom of [5,12,18]){
 const range=ctx.rangeForZoom(lat,zoom);
 assert(Math.abs(ctx.zoomForRange(lat,range)-zoom)<1e-9);
 const metersPerPixel=40075016.686*Math.cos(lat*Math.PI/180)/256/2**zoom;
 assert(Math.abs(2*range*Math.tan(35*Math.PI/360)/800-metersPerPixel)<1e-8,'3D ground scale matches satellite');
}
const handlers={};const target={range:1000,fov:35,center:{lat:42,lng:-71,altitude:20},getBoundingClientRect:()=>({left:0,top:0,width:1000,height:800}),addEventListener:(type,fn)=>handlers[type]=fn};ctx.installGoogle3DGestures(target);
function wheel(modifier){target.range=1000;handlers.wheel({[modifier]:true,deltaY:30,preventDefault(){},stopImmediatePropagation(){}});return target.range;}
assert.equal(wheel('metaKey'),wheel('shiftKey'));
console.log('PASS: Command/Shift wheel zoom match, and 3D/satellite scales match with reversible camera conversion. No network requests.');

vm.runInContext(html.slice(html.indexOf('function cameraBasis3D'),html.indexOf('function installGoogle3DGestures')),ctx);
ctx.pointMarkers=[];ctx.nearest=()=>null;ctx.window={};
let clock=1000,adds=[];ctx.performance={now:()=>clock};ctx.state={dashboard:false,points:[]};ctx.send=(type,p)=>adds.push({type,...p});
const satellite={getCenter:()=>({lat:()=>42,lng:()=>-71}),getZoom:()=>18,getDiv:()=>({clientHeight:800}),getBounds:()=>({getNorthEast:()=>({lat:()=>42.01}),getSouthWest:()=>({lat:()=>41.99})})};
const camera=ctx.satelliteCamera(satellite);
assert.equal(camera.zoom,18);
assert.equal(ctx.rangeForCamera(camera),ctx.rangeForZoom(42,18),'stale bounds must not override the current satellite zoom');
for(const lat of [0,42,75])for(const range of [100,1000,10000,100000]){
 const zoom=ctx.zoomForRange(lat,range);
 const satellite={getCenter:()=>({lat:()=>lat,lng:()=>-71}),getZoom:()=>zoom};
 const returnedRange=ctx.rangeForCamera(ctx.satelliteCamera(satellite));
 assert(Math.abs(returnedRange-range)/range<1e-10,'3D → satellite → 3D must preserve the range');
}
// Exercise the actual capture -> satellite -> capture handoff, including low zoom
// and a non-default FOV, rather than testing two inverse formulas alone.
vm.runInContext(html.slice(html.indexOf('function currentCamera'),html.indexOf('async function setup')),ctx);
ctx.map=target;ctx.provider='google3d';ctx.google3DLibrary={MapMode:{HYBRID:'HYBRID'},AltitudeMode:{RELATIVE_TO_GROUND:'RELATIVE_TO_GROUND'}};
target.removeEventListener=(type,fn)=>{if(handlers[type]===fn)delete handlers[type]};
target.flyCameraTo=async options=>{
 assert(options.durationMillis>0,'must wait for terrain readiness');
 assert.equal(options.endCamera.altitudeMode,'RELATIVE_TO_GROUND');
 target.center={...options.endCamera.center,altitude:176};
 target.range=options.endCamera.range-16; // Model refinement changing the range.
 handlers['gmp-animationend']?.();
};
for(const range of [1000,100000,20000000]){
 target.range=range;target.fov=47;
 const outgoing=ctx.currentCamera();
 const returning=ctx.satelliteCamera({getCenter:()=>({lat:()=>outgoing.lat,lng:()=>outgoing.lng}),getZoom:()=>outgoing.zoom});
 assert(Math.abs(ctx.rangeForCamera(returning)-range)<1e-6);
 assert.equal(returning.fov3D,47);assert.equal(returning.altitude3D,outgoing.altitude3D);
 await ctx.activate3DCamera(target,returning);assert(Math.abs(target.range-range)<1e-6);
 assert.equal(target.cameraPosition.altitude,176+range);
}
// Off-center pinch keeps its Mercator location fixed; the map center must move.
target.range=10000;target.fov=35;target.center={lat:42,lng:-71,altitude:20};
const project=c=>({x:(c.lng+180)/360,y:(1-Math.log(Math.tan(Math.PI/4+c.lat*Math.PI/360))/Math.PI)/2});
function underCursor(){const c=project(target.center),scale=256*2**ctx.zoomForRange(target.center.lat,target.range,800,35);return {x:c.x+300/scale,y:c.y-200/scale};}
const before=underCursor();
const input={clientX:800,clientY:200,preventDefault(){},stopImmediatePropagation(){}};
handlers.gesturestart(input);handlers.gesturechange({...input,scale:1.2});handlers.gestureend(input);
const after=underCursor();assert(Math.abs(after.x-before.x)<1e-10);assert(Math.abs(after.y-before.y)<1e-10);
assert.notEqual(target.center.lng,-71);assert.equal(target.center.altitude,20);
console.log('PASS: camera handoff retains actual range/FOV/altitude at wide zoom; off-center pinch preserves the cursor location.');

})().catch(error=>{console.error(error);process.exitCode=1});
