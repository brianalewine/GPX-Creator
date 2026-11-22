const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
let clock=1000,adds=[],moves=[];
const callbacks={},docEvents={};
const map={center:{lat:38,lng:-78,altitude:176},range:1000,tilt:60,heading:40,fov:35,getBoundingClientRect:()=>({left:0,top:0,width:1000,height:700}),addEventListener:(type,fn)=>callbacks[type]=fn};
const point={id:'a',lat:38,lng:-78,time:10,manual:true};
const ctx={map,performance:{now:()=>clock},window:{},state:{dashboard:false,points:[]},pointMarkers:[],clickTimer:0,draggingID:null,pendingState:null,
 clearTimeout(){},send:(type,p)=>{if(type==='add')adds.push(p);if(type==='move')moves.push(p)},nearest:()=>null,
 document:{addEventListener:(type,fn)=>docEvents[type]=fn,removeEventListener:type=>delete docEvents[type]},
 updateDraggedPath:(id,p)=>Object.assign(point,p)};
vm.createContext(ctx);
vm.runInContext(html.slice(html.indexOf('function cameraBasis3D('),html.indexOf('function installGoogle3DGestures(')),ctx);
for(const tilt of [0,35,65])for(const heading of [0,40,180]){
 map.tilt=tilt;map.heading=heading;
 for(const [x,y] of [[500,350],[600,450],[400,400]]){
  const ground=ctx.groundAt3DPixel(map,x,y);assert(ground);
  const pixel=ctx.pixelFor3DGround(map,ground);
  assert(Math.abs(pixel.x-x)<1e-6&&Math.abs(pixel.y-y)<1e-6,'tilted projection must round-trip');
 }
}
map.tilt=60;map.heading=40;
console.log('PASS: tilted projection round-trips for marker dragging.');
require('./test-map-requirements.cjs');
