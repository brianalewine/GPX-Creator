// Offline integration of the production 3D screen overlay, hover, click and gesture handlers.
const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('Sources/GPXCreator/Resources/map.html','utf8');
const messages=[],frames=[],docEvents={},events={},markers=[];
class Element {
 constructor(){this.style={};this.attrs={};this.children=[];this.rect={left:0,top:0,width:2,height:2}}
 append(e){this.children.push(e)} setAttribute(k,v){this.attrs[k]=v} remove(){this.removed=true}
 getBoundingClientRect(){return this.rect}
 addEventListener(k,f){(this.events||={})[k]=f}
}
const container=new Element();container.rect={left:20,top:30,width:1000,height:700};
class Probe extends Element {constructor(o){super();Object.assign(this,o);markers.push(this)} append(dot){super.append(dot);dot.rect={left:100+this.position.lng*100,top:200+this.position.lat*100,width:2,height:2}}}
let nativeLine;
class HitLine extends Element {constructor(o){super();Object.assign(this,o)}}
class NativeLine extends Element {constructor(o){super();Object.assign(this,o);nativeLine=this}}
const map={center:{lat:0,lng:0},range:1000,tilt:40,heading:10,append(element){if(element instanceof HitLine)this.hitLine=element},getBoundingClientRect:()=>container.rect,addEventListener:(k,f)=>events[k]=f};
const ctx={provider:'google3d',map,pixelFor3DGround:(target,p)=>({x:101+p.lng*100,y:201+p.lat*100}),groundAt3DPixel:(target,x,y)=>({lat:y*.001,lng:x*.001}),disposeZoom(){},document:{getElementById:()=>container,createElementNS:()=>new Element(),createElement:()=>new Element(),addEventListener:(k,f)=>docEvents[k]=f,removeEventListener:k=>delete docEvents[k]},
 google3DLibrary:{MarkerElement:Probe,Polyline3DElement:NativeLine,Polyline3DInteractiveElement:HitLine},requestAnimationFrame:f=>(frames.push(f),frames.length),cancelAnimationFrame(){},setTimeout:()=>1,clearTimeout(){},
 nearest:(points,p)=>({...p,time:5}),pathHover:false,draggingID:null,endPathPreview(){ctx.pathHover=false},window:{cursorAt(){}},performance:{now:()=>clock},state:{dashboard:false,points:[]},screenLineID:0,cursor:null,pointMarkers:[],routeWidth:()=>3.5,send:(type,p)=>messages.push({type,...p}),lineClickTimer:0,lineLastClick:0,showCoordinateEditor(){},creatorLine:null};
let clock=1000;vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('function installGoogle3DAnchorClicks('),html.indexOf('function install3DMarkerDragging(')),ctx);
vm.runInContext(html.slice(html.indexOf('function installGoogle3DGestures('),html.indexOf('function updateDraggedPath(')),ctx);
vm.runInContext(html.slice(html.indexOf('function simplify3DPath('),html.indexOf('function screenLine3D(')),ctx);ctx.mapViewportHeight=()=>700;
const large=Array.from({length:5000},(_,i)=>({lat:Math.sin(i/200)*.001,lng:i*.00001,time:i}));const simplified=ctx.simplify3DPath(large,map);assert(simplified.length<=1000);assert.equal(simplified[0],large[0]);assert.equal(simplified.at(-1),large.at(-1));
ctx.creatorLine=ctx.screenLine3D([{lat:0,lng:0,time:0,manual:true},{lat:0,lng:1,time:10,manual:true}],'#2878d7',3.5);
frames.shift()();assert.equal(nativeLine.strokeWidth,3.5);const originalPath=JSON.stringify(nativeLine.path);assert.equal(nativeLine.path.length,2);
assert.equal(ctx.nearestScreenPath3D(151,216).time,5);assert.equal(ctx.nearestScreenPath3D(151,217),null,'same 15.75px snap radius as satellite');
const realScreenPoints=ctx.creatorLine.screenPoints;
ctx.creatorLine.screenPoints=()=>[{x:100,y:200,depth:100,point:{lat:0,lng:0,time:0}},{x:200,y:200,depth:300,point:{lat:1,lng:1,time:100}}];
assert.equal(ctx.nearestScreenPath3D(150,200).time,25,'screen midpoint must account for perspective depth rather than jump to geographic midpoint');
ctx.creatorLine.screenPoints=realScreenPoints;
map.tilt=80;map.heading=120;map.range=500;frames.shift()();assert.equal(nativeLine.strokeWidth,3.5,'camera never changes stroke width');assert.equal(JSON.stringify(nativeLine.path),originalPath,'camera movement never rewrites geographic geometry');
ctx.installGoogle3DGestures(map);
const event=(x,y,flags={})=>({button:0,detail:1,clientX:x,clientY:y,preventDefault(){},stopImmediatePropagation(){},...flags});
events.pointerdown(event(300,300));docEvents.pointermove(event(320,320));const tilt=map.tilt,heading=map.heading,center={...map.center};
docEvents.pointermove(event(330,310,{shiftKey:true}));assert.equal(map.tilt,tilt+2.5);assert.equal(map.heading,heading+3);
docEvents.pointermove(event(340,300,{metaKey:true}));assert.equal(map.heading,heading+6);assert.equal(map.tilt,tilt+5);
assert.equal(map.center.lat,center.lat);assert.equal(map.center.lng,center.lng,'both modifiers pause panning');
docEvents.pointermove(event(350,310));assert.equal(map.heading,heading+6);assert.equal(map.tilt,tilt+5);
assert(Math.abs(map.center.lat-(center.lat-.01))<1e-9);assert(Math.abs(map.center.lng-(center.lng-.01))<1e-9,'release resumes only the latest 10px pan, without a jump');docEvents.pointerup();
for(const modifier of ['shiftKey','metaKey']){
 map.tilt=40;map.heading=10;events.pointerdown(event(400,400));docEvents.pointermove(event(410,390,{[modifier]:true}));
 assert.equal(map.heading,13);assert.equal(map.tilt,42.5);const before={...map.center};
 docEvents.pointermove(event(420,400));assert.equal(map.heading,13);assert.equal(map.tilt,42.5);assert(Math.abs(map.center.lat-(before.lat-.01))<1e-9);docEvents.pointerup();
}
let blocked=false;events['gmp-click']({preventDefault(){blocked=true},stopImmediatePropagation(){}});assert.equal(blocked,true,'camera drags must not become path clicks');blocked=false;events.pointerdown(event(350,310,{composedPath:()=>[{tagName:'GMP-MARKER-INTERACTIVE'},map]}));
events['gmp-click']({preventDefault(){blocked=true},stopImmediatePropagation(){}});assert.equal(blocked,false,'a completed pan must not block the next anchor click');
ctx.installGoogle3DAnchorClicks(map);
// The click's terrain hit deliberately disagrees with the old camera formula.
ctx.window.nativeMapDoubleClick(700,500);events['gmp-click']({target:map,position:{lat:45.123,lng:-72.456},preventDefault(){}});
assert.deepEqual(messages.at(-1),{type:'add',lat:.5,lng:.7000000000000001});
clock+=500;ctx.window.nativeMapDoubleClick(151,201);events['gmp-click']({target:map,position:{lat:.02,lng:.5},preventDefault(){}});assert.equal(messages.at(-1).type,'insert');assert.equal(messages.at(-1).time,5);
// Model Google's offscreen probe retaining/clamping its last DOM position.
const originalProjection=ctx.pixelFor3DGround;
ctx.pixelFor3DGround=()=>({x:1100,y:300});
assert(ctx.creatorLine.screenPoints().every(p=>p===null),'offscreen geography must not reuse an onscreen/clamped DOM location or switch projections');
ctx.pixelFor3DGround=originalProjection;
assert.equal(ctx.creatorLine.screenPoints()[0].x,101,'returning onscreen restores the terrain-projected position');
ctx.pixelFor3DGround=()=>({x:1100,y:300});
for(const probe of markers.filter(m=>!m.removed))probe.children[0].rect={left:1120,top:300,width:2,height:2};
assert.equal(ctx.creatorLine.screenPoints()[0].x,1121,'genuine offscreen terrain positions are retained for clipping, never replaced by the 1100px estimate');
ctx.pixelFor3DGround=originalProjection;
assert.equal(JSON.stringify(nativeLine.path),originalPath,'stale and moving offscreen probes cannot change the visible path');
const hitLine=map.hitLine;
vm.runInContext('lastPointer3D={x:450,y:350}',ctx);
hitLine.events['gmp-pointermove']({position:{lat:.25,lng:.5}});
assert.equal(ctx.creatorLine.nativeHitAt(450,350).time,5,'native hover works when endpoint probes are offscreen');
assert.equal(ctx.pathHover,true);
hitLine.events['gmp-pointerout']();assert.equal(ctx.pathHover,false);assert.equal(ctx.creatorLine.nativeHitAt(450,350),null);

ctx.creatorLine.remove();assert(nativeLine.removed);assert(markers.every(m=>m.removed),'switching layers removes every projection probe');
console.log('PASS: constant 3D stroke width, identical hover snap radius, mid-drag modifiers, exact terrain placement, path insertion, and complete overlay cleanup.');
