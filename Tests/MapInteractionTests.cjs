const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname,'../Sources/GPXCreator/Resources/map.html'),'utf8');
const script = html.slice(html.lastIndexOf('<script>')+8,html.lastIndexOf('</script>'));
for (const provider of ['osm','google']) {
    const messages=[],frames=[];
    class Marker {
        constructor(position,options) { this.position=position;this.options=options;this.events={};this.visible=true; }
        on(name,fn) { this.events[name]=fn; }
        addListener(name,fn) { this.on(name,fn); }
        addTo() { return this; }
        getLatLng() { return this.position; }
        setLatLng(p) { this.position={lat:p[0],lng:p[1]}; }
        setPosition(p) { this.position=p; }
        setVisible(value) { this.visible=value; }
        setOpacity(value) { this.visible=value!==0; }
        getElement() { return {style:{}}; }
    }
    const context=vm.createContext({
        window:{webkit:{messageHandlers:{bridge:{postMessage:m=>messages.push(m)}}}},
        document:{getElementById:()=>({}),createElement:()=>({}),head:{append(){}},addEventListener(){}},requestAnimationFrame:fn=>(frames.push(fn),frames.length),
        cancelAnimationFrame(){},ResizeObserver:class { observe() {} },clearTimeout,setTimeout,
        L:{Map:{extend:()=>class{}},SVG:{extend:()=>class{}},marker:(p,o)=>new Marker({lat:p[0],lng:p[1]},o),divIcon:o=>o},
        google:{maps:{Marker:class extends Marker { constructor(o){ super(o.position,o); } },SymbolPath:{CIRCLE:'circle'},Size:class {},Point:class {},LatLng:class {constructor(lat,lng){this.lat=lat;this.lng=lng;}}}}
    });
    vm.runInContext(script,context);
    vm.runInContext(`
        provider='${provider}';
        map={zoom:12,getZoom(){return this.zoom},getProjection(){return {fromLatLngToPoint:p=>({x:p.lng*10/4096,y:p.lat*10/4096})}},latLngToContainerPoint:p=>({x:p[1]*10*2**(map.zoom-12),y:p[0]*10*2**(map.zoom-12)})};
        state={finished:true,points:[
            {id:'a',lat:0,lng:0,time:0,manual:true},
            {id:'mid',lat:1,lng:1,time:1,manual:false},
            {id:'b',lat:2,lng:2,time:2,manual:true}
        ]};
        creatorLine={setPath(p){this.path=p},setLatLngs(p){this.path=p},setStyle(){},setOptions(){}};
        state.points.forEach((p,i)=>marker(p,i,3));
    `,context);
    const markers=vm.runInContext('layers',context);
    assert.equal(markers.length,2,'generated points must not obscure the route');
    markers[0].events.dragstart();
    if(provider==='osm')markers[0].position={lat:4,lng:0};
    const event={latLng:{lat:()=>4,lng:()=>0}};
    markers[0].events.drag(event);
    assert.equal(vm.runInContext('state.points[1].lat',context),3);
    assert.equal(vm.runInContext('creatorLine.path.length',context),3);
    assert.equal(messages.filter(m=>m.type==='move').length,0);
    markers[0].events.dragend(event);
    assert.equal(messages.filter(m=>m.type==='move').length,1);
    assert.equal(messages.at(-1).lat,4);
    markers[1].events.click();
    assert.equal(messages.at(-1).type,'seek');
    for(const m of markers){
        const svg=provider==='google'?decodeURIComponent(m.options.icon.url):m.options.icon.html;
        assert.ok(svg.includes('<svg'));
        assert.ok(svg.includes('width="16"'));
        assert.ok(svg.includes('<circle'));
    }
    vm.runInContext(`
        const handle={id:'handle',lat:2.1,lng:2.1,time:1.5,manual:true};
        marker(handle,1,3);
        applyMapStyle();
    `,context);
    assert.equal(markers[2].visible,true,'manual anchors remain available at every zoom');
    assert.equal(markers[0].visible,true);
    assert.equal(markers[1].visible,true);
    vm.runInContext('map.zoom=20;applyMapStyle()',context);
    assert.equal(markers[2].visible,true,'handles appear when sufficiently separated');
    assert.equal(vm.runInContext('routeWidth()',context),3.5);
    while(frames.length)frames.shift()();
    vm.runInContext(`
        const pixel={x:50,y:70,subtract(){return this}};
        const wheelTarget={zoom:12,steps:[],getZoom(){return this.zoom},getMinZoom(){return 1},getMaxZoom(){return 24},getContainer(){return {addEventListener:(name,fn)=>{if(name==='wheel')this.wheel=fn}}},mouseEventToContainerPoint(){return pixel},containerPointToLatLng(){return pixel},getSize(){return {divideBy(){return pixel}}},project(){return pixel},unproject(){return pixel},stop(){},_moveStart(){},_moveEnd(){},fire(){},_move(center,zoom){this.zoom=zoom;this.steps.push(zoom)}};
        map=wheelTarget;installSmoothWheel(wheelTarget);
        wheelTarget.wheel({deltaY:-120,deltaMode:0,preventDefault(){},stopPropagation(){}});
    `,context);
    while(frames.length)frames.shift()();
    assert.equal(vm.runInContext('wheelTarget.steps.length',context),1,'wheel changes coalesce into one display frame');
    assert.equal(vm.runInContext('wheelTarget.zoom',context),12.5);
}
console.log('PASS: both providers preserve live drag commits, endpoint markers, manual anchors, constant line width, and frame-coalesced wheel zoom.');
