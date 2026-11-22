// Offline only: no keys, network, or Google API calls.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
const setupSource=html.slice(html.indexOf('async function setup('),html.indexOf('let clickTimer,'));
let loads=0,imports=0,creates=0,release;
const loading=new Promise(resolve=>release=resolve);
const element={addEventListener(){},cloneNode(){return this;},replaceWith(){},append(target){target.attached=true;}};
const library={QualityMode:{PERFORMANCE:'PERFORMANCE'},MapMode:{HYBRID:'HYBRID'},GestureHandling:{GREEDY:'GREEDY'},Map3DElement:class {
 constructor(options){creates++;assert.equal(options.gestureHandling,'GREEDY');assert.equal(options.mode,undefined,'rendering starts only after attachment');Object.assign(this,options);}
 addEventListener(){} remove(){}
}};
const ctx={installPathDragging(){},remove(){},map:null,provider:'',coverageLayer:null,setupRevision:0,disposeZoom(){},layers:[],cursor:null,coordEditor:null,
 document:{getElementById:()=>element},previewPointer(){},endPathPreview(){},savedCamera:()=>({lat:42,lng:-71,zoom:12}),rangeForZoom:()=>1000,rangeForCamera:()=>1000,activate3DCamera:(target)=>{assert.equal(target.attached,true,'initial camera must be applied after attachment');target.mode='HYBRID'},requestAnimationFrame:callback=>callback(),installGoogle3DAnchorClicks(){},
 googleLoad:async()=>{loads++;await loading;},google:{maps:{importLibrary:async()=>{imports++;return library;}}},
 installGoogle3DGestures(){},notice(){},setTimeout,clearTimeout,send(){},window:{}};
vm.createContext(ctx);vm.runInContext(setupSource,ctx);
vm.runInContext('async function renderUpdate(s){await setup(s)}',ctx);
vm.runInContext(html.slice(html.indexOf('let updateRunning=false,queuedUpdate=null;'),html.indexOf('window.cursorAt=function')),ctx);
(async()=>{
 const initial=ctx.window.update({google:true,google3D:true,key:'offline-placeholder'});
 for(let i=0;i<100;i++)ctx.window.update({google:true,google3D:true,key:'offline-placeholder',selected:String(i)});
 release();await initial;
 assert.equal(loads,1);assert.equal(imports,1);assert.equal(creates,1,'rapid updates must create only one 3D map');
 ctx.provider='';ctx.map=null;
 library.Map3DElement=class {constructor(){creates++;throw Error('simulated initialization failure');}};
 await ctx.window.update({google:true,google3D:true,key:'offline-placeholder'});
 for(let i=0;i<100;i++)await ctx.window.update({google:true,google3D:true,key:'offline-placeholder'});
 assert.equal(creates,2,'failed initialization must not retry on state updates');
 console.log('PASS: 100 overlapping updates create one 3D map; enum options are valid; 100 updates after failure cause zero retries. No network requests.');
})().catch(e=>{console.error(e);process.exitCode=1});
