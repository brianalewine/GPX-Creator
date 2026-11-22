const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
const events={},messages=[],frames=[];
let zoom=19,center={x:0,y:0},stopped=false;
const ctx={window:{addEventListener(){}},state:{dashboard:false},send:(type,data)=>messages.push({type,...data}),clickTimer:null,lastMapClick:0,
 clearTimeout(){},setTimeout:()=>1,cancelAnimationFrame(){},requestAnimationFrame:fn=>{frames.push(fn);return frames.length},
 disposeZoom(){}};
vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('function installGoogleAnchorClicks('),html.indexOf('function installGoogle3DAnchorClicks(')),ctx);
ctx.installGoogleAnchorClicks({addListener:(type,fn)=>events[type]=fn});
events.click();assert.equal(messages.length,0,'single clicks must not create anchors');
events.dblclick({latLng:{lat:()=>42,lng:()=>-71},stop:()=>stopped=true});
assert(stopped);assert.equal(messages.length,1);assert.equal(messages[0].type,'add');
ctx.state.dashboard=true;events.dblclick({latLng:{}});assert.equal(messages.length,1,'dashboard double-click must not create anchors');
const gestures={};
const target={getDiv:()=>({getBoundingClientRect:()=>({left:0,top:0,width:1000,height:700}),addEventListener:(type,fn)=>gestures[type]=fn}),
 get:name=>name==='maxZoom'?24:0,getProjection:()=>({fromLatLngToPoint:p=>p,fromPointToLatLng:p=>p}),getCenter:()=>center,
 getZoom:()=>zoom,setZoom:value=>zoom=value,moveCamera:camera=>center=camera.center};
vm.runInContext(html.slice(html.indexOf('function installGooglePinch('),html.indexOf('function installGoogleAnchorClicks(')),ctx);
ctx.installGooglePinch(target);
gestures.wheel({clientX:800,clientY:200,deltaY:-2400,deltaMode:0,preventDefault(){},stopImmediatePropagation(){}});
frames.shift()();assert.equal(zoom,24,'must reach the same configured zoom limit as OpenStreetMap');
assert(Math.abs(center.x+300/2**zoom-300/2**19)<1e-12,'cursor anchor survives deep zoom');
console.log('PASS: native Google double-click creates one anchor; dashboard double-click creates none; Google pinch/wheel can reach zoom 24 without a map-type cap. No network requests.');
