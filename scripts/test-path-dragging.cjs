const fs=require('fs'),vm=require('vm'),assert=require('assert/strict');
const html=fs.readFileSync('Sources/GPXCreator/Resources/map.html','utf8');
for(const provider of ['google3d','google','osm']){
 const events={},doc={},messages=[];
 const ctx={anchorAtScreen:()=>null,provider,state:{points:[{id:'a',lat:0,lng:0,time:0,manual:true},{id:'b',lat:1,lng:1,time:10,manual:true}]},draggingID:null,pendingState:null,lineClickTimer:0,renderSignature:'x',
 document:{addEventListener:(t,f)=>doc[t]=f,removeEventListener:t=>delete doc[t]},window:{cursorAt(){}},clearTimeout(){},marker(){},routeWidth:()=>3.5,
 nearest:()=>({lat:.5,lng:.5,time:5}),nearestScreenPath3D:()=>({lat:.5,lng:.5,time:5}),
 updateDraggedPath(id,p){Object.assign(ctx.state.points.find(p=>p.id===id),p)},send:(type,p)=>messages.push({type,...p}),
 google:{maps:{LatLng:class{constructor(lat,lng){this.lat=lat;this.lng=lng}}}},map:{get:()=>true,setOptions(o){ctx.panEnabled=o.draggable},dragging:{enabled:()=>true,disable(){ctx.panEnabled=false},enable(){ctx.panEnabled=true}},getProjection:()=>({fromLatLngToPoint:p=>({x:p.lng,y:p.lat})}),getZoom:()=>0,latLngToContainerPoint:()=>({distanceTo:()=>0})}};
 vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function installPathDragging('),html.indexOf('function installGoogleAnchorClicks(')),ctx);
 ctx.pointerGround=e=>({lat:e.clientY/100+(provider==='google3d'?20:0),lng:e.clientX/100+(provider==='google3d'?30:0)});ctx.installPathDragging({addEventListener:(t,f)=>events[t]=f,removeEventListener:t=>delete events[t]});
 const event=(x,y)=>({button:0,clientX:x,clientY:y,composedPath:()=>[],preventDefault(){},stopImmediatePropagation(){}});
 events.pointerdown(event(50,50));if(provider!=='google3d')assert.equal(ctx.panEnabled,false,'basemap panning must be disabled before movement');assert(events.mousedown,'native compatibility mouse events must be blocked');doc.pointermove(event(53,50));if(provider==='google3d'){const p=ctx.state.points.find(p=>p.id==='__insert__');assert(Math.abs(p.lat-.5)<1e-8);assert(Math.abs(p.lng-.53)<1e-8,'creation must preserve grab offset even when the terrain ray differs by 30 degrees')}doc.pointermove(event(70,80));assert.equal(ctx.state.points.length,3);assert.equal(ctx.draggingID,'__insert__');doc.pointerup(event(70,80));
 assert.equal(messages.length,1);assert.equal(messages[0].type,'insertDragged');assert.equal(messages[0].time,5);assert(Math.abs(messages[0].lat-.8)<1e-8);assert.equal(ctx.state.points.length,2);assert.equal(ctx.draggingID,null);if(provider!=='google3d')assert.equal(ctx.panEnabled,true);assert(!events.mousedown,'mouse blocker must be removed after release');
 events.pointerdown(event(50,50));doc.pointerup(event(50,50));assert.equal(messages.length,1,'stationary clicks must not insert');
}
// A retargeted event over an existing 3D anchor must never start insertion.
{
 const events={};let drags=0;
 const ctx={provider:'google3d',state:{dashboard:false},draggingID:null,anchorAtScreen:()=>({marker:{_beginAnchorDrag(){drags++}}})};
 vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function installPathDragging('),html.indexOf('function installGoogleAnchorClicks(')),ctx);
 ctx.installPathDragging({addEventListener:(t,f)=>events[t]=f});
 events.pointerdown({button:0,clientX:10,clientY:10});assert.equal(drags,1);
}
console.log('PASS: path drags create and move one anchor, commit once, and preserve stationary clicks in all three renderers.');
// Production route updates must move the temporary marker and interpolated
// samples together, leaving no marker behind at the insertion origin.
for(const provider of ['google','google3d','osm']){
 const a={id:'a',lat:0,lng:0,time:0,manual:true},b={id:'b',lat:10,lng:10,time:10,manual:true},temp={id:'__insert__',lat:5,lng:5,time:5,manual:true},sample={id:'sample',lat:2,lng:2,time:2,manual:false};
 const marker={setPosition(p){this.position=p},setLatLng(p){this.position={lat:p[0],lng:p[1]}}};
 const line={setPath(p){this.path=p},setLatLngs(p){this.path=p}};
 const ctx={provider,state:{points:[a,sample,temp,b]},pointMarkers:[{point:temp,marker}],generatedMarkers:new Map(),creatorLine:line,creatorHitLine:null,window:{cursorAt(){}},scheduleMapStyle(){}};
 vm.createContext(ctx);vm.runInContext(html.slice(html.indexOf('function updateDraggedPath('),html.indexOf('let generatedMarkers=')),ctx);
 ctx.updateDraggedPath('__insert__',{lat:7,lng:8});
 assert.equal(marker.position.lat,7);assert.equal(marker.position.lng,8);assert(Math.abs(sample.lat-2.8)<1e-8);assert.equal(ctx.state.points.length,4);
}
console.log('PASS: temporary anchor marker, adjacent route samples, and route line update together in every renderer.');
