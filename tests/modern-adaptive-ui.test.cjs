const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const ts = require('typescript');
const React = require('react');
const { AndroidConfig } = require('@expo/config-plugins');
const { DOMParser } = require('@xmldom/xmldom');
const root = path.resolve(__dirname, '..');

// Real project TSX + real installed Expo modifier transforms; platform/UI mounts are adapters.
function fixture({width=360,height=800,fontScale=1,platform='android',insets={top:24,bottom:24,left:0,right:0},session=null,isLoading=false}={}) {
  const cache = new Map();
  const flatten = style => Object.assign({}, ...[style].flat(Infinity).filter(Boolean));
  const react = {...React,useEffect:()=>{},useState:value=>[value,()=>{}],useRef:current=>({current}),useMemo:fn=>fn(),useCallback:fn=>fn};
  const Stack = Object.assign(({children})=>React.createElement('Stack',null,children),{
    Screen:'Screen',Protected:({guard,children})=>guard?children:null,
  });
  const ui = Object.fromEntries(['Button','Column','Host','Spacer','Text','ScrollView'].map(name=>[name,`UI${name}`]));
  const native = {Platform:{OS:platform},StyleSheet:{create:value=>value,flatten,hairlineWidth:0.5},
    useWindowDimensions:()=>({width,height,fontScale,scale:1}),View:'View',Text:'Text',Pressable:'Pressable',ImageBackground:'ImageBackground',ScrollView:'ScrollView',AppState:{}};
  const boundaries = {
    react,'react/jsx-runtime':require('react/jsx-runtime'),'react-native':native,
    expo:{requireNativeModule:name=>{assert.equal(name,'ExpoUI');return {};}},
    '@expo/ui':ui,'react-native-safe-area-context':{SafeAreaView:'SafeAreaView',useSafeAreaInsets:()=>insets,SafeAreaProvider:'SafeAreaProvider'},
    'lucide-react-native':Object.fromEntries(['ChevronRight','MapPin','Power','Settings','Shield'].map(name=>[name,name])),
    '@/native/cryptoPolyfill':{},'@/observability/sentry':{initSentry:()=>{},captureError:()=>{}},
    '@tanstack/react-query':{QueryClient:class {},QueryClientProvider:'QueryClientProvider',focusManager:{}},
    'expo-notifications':{setNotificationHandler:()=>{}},'expo-router':{Stack},'expo-status-bar':{StatusBar:'StatusBar'},
    '@/auth/session-context':{SessionProvider:'SessionProvider',useSession:()=>({session,isLoading})},
    '@/auth/splash-screen-controller':{SplashScreenController:'SplashScreenController'},'@/auth/systemAuth':{},'@/navigation/website':{},
    '@/components/android-update-overlay':{AndroidUpdateOverlay:'AndroidUpdateOverlay'},'@/components/ios-update-overlay':{IOSUpdateOverlay:'IOSUpdateOverlay'},
    '@/components/ota-update-overlay':{OtaUpdateOverlay:'OtaUpdateOverlay',OtaUpdateProvider:'OtaUpdateProvider'},
    '@/debug/render-profiler':{RenderProfilerOverlay:'RenderProfilerOverlay'},'@/ui/toast':{ToastProvider:'ToastProvider'},
    '@/vpn/vpn-connection-context':{VpnConnectionProvider:'VpnConnectionProvider'},'@/realtime/customer-realtime-context':{CustomerRealtimeProvider:'CustomerRealtimeProvider'},
  };
  function load(file) {
    const absolute=path.isAbsolute(file)?file:path.join(root,file);
    if(cache.has(absolute))return cache.get(absolute).exports;
    if(absolute.endsWith('.json'))return JSON.parse(fs.readFileSync(absolute,'utf8'));
    if(absolute.endsWith('.png'))return 'fixture-photo';
    const module={exports:{}};cache.set(absolute,module);
    const code=ts.transpileModule(fs.readFileSync(absolute,'utf8'),{fileName:absolute,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText;
    new Function('require','module','exports','__DEV__',code)(id=>{
      if(Object.hasOwn(boundaries,id))return boundaries[id];
      let next;
      if(id.startsWith('@/'))next=path.join(root,'src',id.slice(2));
      else if(id==='@expo/ui/jetpack-compose/modifiers')next=path.join(root,'node_modules/@expo/ui/src/jetpack-compose/modifiers/index.ts');
      else if(id==='@expo/ui/swift-ui/modifiers')next=path.join(root,'node_modules/@expo/ui/src/swift-ui/modifiers/index.ts');
      else if(id.startsWith('.'))next=path.resolve(path.dirname(absolute),id);
      else throw Error(`Unadapted dependency ${id}`);
      const source=[next,next+'.ts',next+'.tsx',path.join(next,'index.ts')].find(p=>fs.existsSync(p)&&fs.statSync(p).isFile());assert.ok(source,`Missing ${id}`);return load(source);
    },module,module.exports,false);
    return module.exports;
  }
  return {load,flatten};
}
function expand(tree) {
  if(Array.isArray(tree))return tree.flatMap(expand);
  if(!tree||typeof tree!=='object')return tree;
  if(typeof tree.type==='function')return expand(tree.type(tree.props));
  if(typeof tree.type?.type==='function')return expand(tree.type.type(tree.props));
  return {...tree,props:{...tree.props,children:[tree.props?.children].flat(Infinity).map(expand)}};
}
function nodes(tree,ancestors=[]) {
  if(!tree||typeof tree!=='object')return [];
  return [{tree,ancestors},...[tree.props?.children].flat(Infinity).flatMap(child=>nodes(child,[...ancestors,tree]))];
}
const props = {connectionPhase:'idle',latencyText:'18 мс',selectionMode:'auto',protocolLabel:'AWG',location:{id:'de',countryCode:'DE',city:'Frankfurt'},
  onPowerPress:()=>{},onSettingsPress:()=>{},onLocationPress:()=>{},powerButtonDisabled:false,pulseProgress:{}};
const styleOf=(f,node)=>f.flatten(typeof node.props.style==='function'?node.props.style({pressed:false}):node.props.style);

test('Android native orientation/back settings agree with real Expo config and retain service/auth boundaries',async()=>{
  const f=fixture();const config=f.load('app.config.ts').default({config:{}});
  const manifest=await AndroidConfig.Manifest.readAndroidManifestAsync(path.join(root,'android/app/src/main/AndroidManifest.xml'));
  const application=AndroidConfig.Manifest.getMainApplicationOrThrow(manifest),activity=AndroidConfig.Manifest.getMainActivityOrThrow(manifest);
  assert.equal(config.android.predictiveBackGestureEnabled,true);
  assert.equal(application.$['android:enableOnBackInvokedCallback'],'true');
  assert.equal(config.orientation,'default');assert.ok([undefined,'unspecified'].includes(activity.$['android:screenOrientation']));
  const generated=AndroidConfig.Orientation.setAndroidOrientation(config,structuredClone(manifest));
  assert.equal(AndroidConfig.Manifest.getMainActivityOrThrow(generated).$['android:screenOrientation'],'unspecified');
  assert.equal(activity.$['android:launchMode'],'singleTask');
  const auth=activity['intent-filter'].flatMap(x=>x.data??[]).find(x=>x.$['android:host']==='auth');
  assert.deepEqual(auth.$,{'android:scheme':'vexguard','android:host':'auth','android:pathPrefix':'/callback'});
  const open=activity['intent-filter'].find(x=>(x.data??[]).some(d=>d.$['android:host']==='open'));
  assert.deepEqual(open.data.map(d=>d.$),[{'android:scheme':'vexguard','android:host':'open'}]);
  assert.deepEqual(config.android.intentFilters.find(x=>x.data.some(d=>d.host==='open')).data,[{scheme:'vexguard',host:'open'}]);
  const systemVpn=(application.service??[]).filter(s=>(s['intent-filter']??[]).some(x=>(x.action??[]).some(a=>a.$['android:name']==='android.net.VpnService')));
  assert.deepEqual(systemVpn.map(x=>x.$['android:name']),['.vpn.VexBootProtectionService']);
});
test('Android adaptation does not widen the existing iPhone/iPad native orientation contract',()=>{
  const config=fixture().load('app.config.ts').default({config:{}});
  const native=new DOMParser().parseFromString(fs.readFileSync(path.join(root,'ios/VEX/Info.plist'),'utf8'),'application/xml');
  for(const key of ['UISupportedInterfaceOrientations','UISupportedInterfaceOrientations~ipad']){
    const node=Array.from(native.getElementsByTagName('key')).find(x=>x.textContent===key);
    let value=node.nextSibling;while(value&&value.nodeType!==1)value=value.nextSibling;
    assert.deepEqual(config.ios.infoPlist[key],Array.from(value.getElementsByTagName('string')).map(x=>x.textContent));
  }
});
for(const width of [280,320,800])test(`VexScreen respects horizontal safe bounds at ${width}dp`,()=>{
  const insets={left:44,right:28,top:24,bottom:24};const f=fixture({width,height:360,insets});
  const tree=expand(f.load('src/ui/vex-ui.tsx').VexScreen({children:'fixture'}));
  const safe=nodes(tree).find(x=>x.tree.type==='SafeAreaView').tree;
  assert.ok(safe.props.edges.includes('left')&&safe.props.edges.includes('right'));
  const shell=nodes(safe).find(x=>styleOf(f,x.tree).width!=null).tree;
  const style=styleOf(f,shell);assert.ok(style.width<=width-insets.left-insets.right);assert.ok(style.width>=0&&style.width<=430);
});
for(const dims of [{width:320,height:640,fontScale:2},{width:800,height:360,fontScale:2},{width:360,height:800,fontScale:1}]){
 test(`welcome CTA grows and scrolls instead of fixing native text height (${dims.width}x${dims.height}, font${dims.fontScale})`,()=>{
  const f=fixture(dims);let continued=0;const tree=expand(f.load('src/components/universal-sign-in-welcome.tsx').UniversalSignInWelcome({onContinue:()=>continued++}));
  const entry=nodes(tree).find(x=>x.tree.type==='UIButton');assert.ok(entry.ancestors.some(x=>x.type==='UIScrollView'));
  const modifiers=f.load('node_modules/@expo/ui/src/universal/transformStyle.android.ts').transformToModifiers(entry.tree.props.style,{},entry.tree.props.modifiers);
  assert.equal(modifiers.some(x=>x.$type==='height'||x.$type==='size'),false);
  assert.ok(modifiers.some(x=>x.$type==='defaultMinSize'&&x.minHeight>=48));
  entry.tree.props.onPress();assert.equal(continued,1);
 });
}
for(const dims of [{width:320,height:480,fontScale:2},{width:800,height:360,fontScale:2}]){
 test(`real hero keeps full-size readable actions at ${dims.width}x${dims.height} font${dims.fontScale}`,()=>{
  const f=fixture(dims);const calls=[];
  const tree=expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero({...props,onPowerPress:()=>calls.push('power'),onSettingsPress:()=>calls.push('settings'),onLocationPress:()=>calls.push('location')}));
  const entries=nodes(tree);const buttons=entries.filter(x=>x.tree.props?.accessibilityRole==='button');assert.equal(buttons.length,3);
  const power=buttons.find(x=>x.tree.props.accessibilityLabel==='Подключить').tree;const powerStyle=styleOf(f,power);
  assert.notEqual(typeof powerStyle.height,'number');assert.ok(powerStyle.minHeight>=48);assert.ok(powerStyle.width==='100%'||powerStyle.width<=dims.width-48);
  for(const entry of entries.filter(x=>x.tree.type==='Text')){assert.notEqual(entry.tree.props.allowFontScaling,false);assert.notEqual(entry.tree.props.adjustsFontSizeToFit,true);assert.equal(entry.tree.props.numberOfLines,undefined);}
  const brand=entries.find(x=>x.tree.props.accessibilityLabel==='VEX VPN').tree;assert.notEqual(styleOf(f,brand).position,'absolute');
  buttons.forEach(x=>x.tree.props.onPress());assert.deepEqual(calls,['settings','power','location']);
  const location=buttons.find(x=>x.tree.props.accessibilityLabel?.startsWith('Выбрать локацию')).tree;assert.match(location.props.accessibilityLabel,/Выбранный протокол: AWG/);
  assert.equal(entries.find(x=>x.tree.props.testID==='home-selected-protocol').tree.props.children[0],'AWG');
 });
}
test('portrait appearance and existing disabled/busy semantics are preserved',()=>{
 const f=fixture();const normal=expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero(props));
 const power=nodes(normal).find(x=>x.tree.props.accessibilityLabel==='Подключить').tree;assert.equal(styleOf(f,power).height,184);
 const pending=expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero({...props,connectionPhase:'connecting',powerButtonDisabled:true}));
 const control=nodes(pending).find(x=>x.tree.props.accessibilityState?.busy).tree;assert.equal(control.props.disabled,true);assert.equal(control.props.accessibilityState.disabled,true);
});
for(const state of [{session:null,isLoading:false},{session:{user:{id:'fixture'}},isLoading:false},{session:null,isLoading:true}]){
 test(`actual root preserves auth/callback/protected routes (session=${!!state.session}, loading=${state.isLoading})`,()=>{
  const tree=expand(fixture(state).load('app/_layout.tsx').default());const names=nodes(tree).filter(x=>x.tree.type==='Screen').map(x=>x.tree.props.name);
  if(state.isLoading)assert.deepEqual(names,[]);else assert.deepEqual(names,['index','auth/callback',state.session?'(app)':'sign-in']);
 });
}
test('actual root recovery retry remains reachable through a scroll container',()=>{
 const f=fixture({width:640,height:320,fontScale:2});let retries=0;
 const tree=expand(f.load('app/_layout.tsx').ErrorBoundary({error:new Error('fixture'),retry:()=>retries++}));
 const entry=nodes(tree).find(x=>x.tree.type==='UIButton');assert.ok(entry.ancestors.some(x=>x.type==='UIScrollView'));
 entry.tree.props.onPress();assert.equal(retries,1);
});

test('short landscape reduces empty spacing without owning a nested scroll view',()=>{
 const f=fixture({width:800,height:360});const tree=expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero(props));const entries=nodes(tree);
 assert.equal(entries.some(x=>x.tree.type==='ScrollView'||x.tree.type==='UIScrollView'),false);
 assert.ok(entries.some(x=>styleOf(f,x.tree).minHeight===360));
 assert.ok(entries.some(x=>{const style=styleOf(f,x.tree);return style.minHeight===216&&style.paddingTop===0;}));
});
for (const {width,fontScale} of [
 {width:280,fontScale:1},{width:280,fontScale:1.3},{width:280,fontScale:2},
 {width:0,fontScale:1},{width:-10,fontScale:1},{width:96,fontScale:2},{width:312,fontScale:1.3},
]) test(`hero power frame respects remaining safe width at ${width}dp font${fontScale}`,()=>{
 const f=fixture({width,height:480,fontScale,insets:{left:44,right:28,top:24,bottom:24}});
 const entries=nodes(expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero(props)));
 const power=entries.find(x=>x.tree.props.accessibilityLabel==='Подключить');
 const frame=power.ancestors.find(x=>styleOf(f,x).borderWidth===1);assert.ok(frame);
 const frameStyle=styleOf(f,frame), availableWidth=Math.max(0,width-44-28-48);
 assert.ok(frameStyle.width>=0&&frameStyle.width<=availableWidth,`frame ${frameStyle.width} exceeds safe content ${availableWidth}`);
 const buttonStyle=styleOf(f,power.tree);
 if(availableWidth<192||fontScale>1.3){
  assert.equal(frameStyle.width,Math.min(320,availableWidth));assert.equal(buttonStyle.width,'100%');
  assert.equal(typeof buttonStyle.height,'string');assert.ok(buttonStyle.minHeight>=48);
 }else{assert.equal(frameStyle.width,192);assert.equal(buttonStyle.width,184);assert.equal(buttonStyle.height,184);}
 assert.equal(power.tree.props.disabled,false);assert.equal(power.tree.props.accessibilityRole,'button');
});

test('hero action stays inside asymmetric landscape cutouts',()=>{
 const f=fixture({width:320,height:480,fontScale:2,insets:{left:44,right:28,top:24,bottom:24}});
 const entries=nodes(expand(f.load('src/components/location-home-hero.tsx').LocationHomeHero(props)));
 assert.ok(entries.some(x=>{const style=styleOf(f,x.tree);return style.paddingLeft>=68&&style.paddingRight>=52;}));
 const power=entries.find(x=>x.tree.props.accessibilityLabel==='Подключить');
 const frame=power.ancestors.find(x=>styleOf(f,x).minHeight===192);assert.ok(frame);assert.ok(styleOf(f,frame).width<=200);
});


for (const platform of ['android','web','ios']) test(`actual HomeBody keeps short-screen content scrollable on ${platform}`, () => {
  const filename=path.join(root,'src/screens/home-screen.tsx');
  const tree=ts.createSourceFile(filename,fs.readFileSync(filename,'utf8'),ts.ScriptTarget.Latest,true);
  const declaration=tree.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name?.text==='HomeBody');
  assert.ok(declaration);
  const code=ts.transpileModule(declaration.getText(tree),{compilerOptions:{jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const load=id=>{assert.equal(id,'react/jsx-runtime');return require(id);};
  const body=new Function('require','exports','Platform','ScrollView',code+';return HomeBody;')(load,{}, {OS:platform},'ScrollView');
  const element=body({children:'fixture'});
  assert.equal(element.type,'ScrollView');assert.equal(element.props.contentContainerStyle.flexGrow,1);assert.equal(element.props.children,'fixture');
});


test('local VPN test receiver is restricted to privileged operators and absent from production manifest',async()=>{
  const local=await AndroidConfig.Manifest.readAndroidManifestAsync(path.join(root,'android/app/src/local/AndroidManifest.xml'));
  const receiver=local.manifest.application[0].receiver.find(v=>v.$['android:name']==='.vpn.VexVpnTestReceiver');
  assert.ok(receiver);assert.equal(receiver.$['android:exported'],'true');assert.equal(receiver.$['android:permission'],'android.permission.DUMP');
  const production=await AndroidConfig.Manifest.readAndroidManifestAsync(path.join(root,'android/app/src/main/AndroidManifest.xml'));
  assert.equal((AndroidConfig.Manifest.getMainApplicationOrThrow(production).receiver??[]).some(v=>v.$['android:name']==='.vpn.VexVpnTestReceiver'),false);
});
