// Offline regression: exercise the real dashboard hover-update path.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
(async()=>{
 let attached,attachments=0,styles={};
 const map={_gpxSatellite:false};attached=map;
 const tracks=[{id:'a',points:[]},{id:'b',points:[]}];
 const initial={google:true,osmSatellite:false,google3D:false,googleSatellite:false,key:'offline',dashboard:true,points:[],focusedAnchorID:'',tracks,duration:1,hasVideo:false,importedGPX:false,fit:'',coverage:true,selected:'b',hovered:''};
 const ctx={map,provider:'google',state:initial,draggingID:null,fit:'',routeBlue:'#2878d7',routeWidth:()=>3.5,
 dashboardLines:Object.fromEntries(['a','b'].map(id=>[id,{setOptions:options=>styles[id]=options}])),
 coverageLayer:{getMap:()=>attached,setMap:target=>{attachments++;attached=target}},
 renderSignature:JSON.stringify([true,false,false,false,'offline',true,[],'',tracks,1,false,false]),setup:async()=>{},window:{}};
 vm.createContext(ctx);
 vm.runInContext(html.slice(html.indexOf('function styleDashboardLines('),html.indexOf('function applyMapStyle(')),ctx);
 vm.runInContext(html.slice(html.indexOf('async function renderUpdate('),html.indexOf('// Coalesce state changes')),ctx);
 vm.runInContext(html.slice(html.indexOf('let updateRunning=false,queuedUpdate=null;'),html.indexOf('window.cursorAt=function')),ctx);
 for(let i=0;i<100;i++)await ctx.window.update({...initial,hovered:i%2?'a':''});
 assert.equal(attachments,0,'hover must never reattach Street View coverage');
 assert.equal(styles.a.strokeColor,'#ff8a1f');assert.equal(styles.a.strokeWeight,5);
 assert.equal(styles.b.strokeColor,'#1d65bd');assert.equal(styles.b.strokeWeight,3.5);
 await ctx.window.update({...initial,hovered:'',coverage:false});
 assert.equal(styles.a.strokeColor,'#2878d7');assert.equal(styles.a.strokeWeight,3.5);
 assert.equal(attachments,1,'disabling coverage changes the attachment exactly once');
 await ctx.window.update({...initial,hovered:'a',coverage:false});assert.equal(attachments,1);
 await ctx.window.update(initial);assert.equal(attachments,2,'enabling coverage reattaches once');
 ctx.syncCoverage({...initial,dashboard:false});assert.equal(attached,null,'creator must never display dashboard coverage');
 console.log('PASS: 100 dashboard hover updates do not refresh coverage; hovered lines are orange/bolder; selection styling and coverage toggles remain independent. No network requests.');
})().catch(error=>{console.error(error);process.exitCode=1});
