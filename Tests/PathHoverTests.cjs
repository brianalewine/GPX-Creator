const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=fs.readFileSync('Sources/GPXCreator/Resources/map.html','utf8');
const nearest=html.slice(html.indexOf('function nearest('),html.indexOf('let pathHover='));
const hover=html.slice(html.indexOf('let pathHover='),html.indexOf('const startSVG'));
for(const provider of ['osm','esri','google']){
    const messages=[],cursors=[],listeners={};
    const projection={fromLatLngToPoint:p=>({x:p.lng,y:p.lat}),fromPointToLatLng:p=>({lat:()=>p.y,lng:()=>p.x})};
    const context=vm.createContext({provider,state:{points:[{lat:0,lng:0,time:0},{lat:0,lng:100,time:100}]},draggingID:null,
        map:{mouseEventToLatLng:e=>({lat:e.clientY,lng:e.clientX}),latLngToContainerPoint:p=>({x:p[1],y:p[0]}),getProjection:()=>projection,getCenter:()=>({lat:0,lng:0}),getZoom:()=>0,getDiv:()=>({getBoundingClientRect:()=>({left:0,top:0,width:0,height:0})})},
        google:{maps:{Point:class{constructor(x,y){this.x=x;this.y=y}},LatLng:class{constructor(lat,lng){this.lat=lat;this.lng=lng}}}},
        document:{getElementById:()=>({addEventListener:(name,fn)=>listeners[name]=fn})},
        window:{cursorAt:p=>cursors.push(p)},send:(type,p)=>messages.push({type,...p}),setMapPathCursor:()=>{},routeWidth:()=>3.5});
    vm.runInContext(nearest+hover,context);
    listeners.mousemove({clientX:3.25,clientY:2});
    assert.equal(messages.at(-1).time,3.25,'hover must interpolate near an anchor without snapping');
    listeners.mousemove({clientX:42.75,clientY:15});
    assert.equal(messages.at(-1).time,42.75,'expanded path hover area remains active');
    listeners.mousemove({clientX:42.75,clientY:16});
    assert.equal(messages.at(-1).type,'previewEnd');
    assert.equal(cursors.at(-1),null,'leaving hit area clears cursor');
    listeners.mousemove({clientX:50,clientY:0});
    listeners.mouseleave();
    assert.equal(cursors.at(-1),null,'leaving map clears cursor');
}
console.log('Path hover: continuous interpolation and exit cleanup passed for OSM, Esri, Google.');
