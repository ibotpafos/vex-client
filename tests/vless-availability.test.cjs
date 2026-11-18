const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const ts = require('typescript');
const React = require('react');
const {loadModule} = require('./vpn-module-loader.cjs');
const root = path.resolve(__dirname, '..');
const servers = loadModule('src/vpn/serverSelection.ts');
const transports = loadModule('src/vpn/transport.ts');
const ready = {id:'fi',availability:'available',status:'healthy',healthyNodes:1,awg3Nodes:1,capabilities:['vless-xhttp-v1']};

test('VLESS requires an explicitly advertised usable server, never AWG health alone', () => {
  assert.equal(servers.locationSupportsVless(ready),true);
  for (const patch of [{capabilities:[]},{capabilities:['vless']},{capabilities:undefined},{capabilities:'vless-xhttp-v1'},
    {availability:'maintenance'},{availability:'hidden'},{healthyNodes:0},{healthyNodes:NaN},{status:'offline'},{awg3Nodes:0}]) {
    assert.equal(servers.locationSupportsVless({...ready,...patch}),false,JSON.stringify(patch));
  }
});

test('availability follows the selected server or any usable server in server-auto mode', () => {
  assert.equal(servers.hasAvailableVlessLocation([ready],'manual','fi'),true);
  assert.equal(servers.hasAvailableVlessLocation([ready],'manual','de'),false);
  assert.equal(servers.hasAvailableVlessLocation([ready],'auto','de'),true);
  assert.equal(servers.hasAvailableVlessLocation(null,'auto','fi'),false);
  assert.equal(servers.hasAvailableVlessLocation([],'auto','fi'),false);
});

test('an old VLESS preference becomes visibly Auto while unavailable without erasing the saved choice', () => {
  for (const [input,available,output] of [['vless',false,'auto'],['vless',true,'vless'],['auto',false,'auto'],['amneziawg',false,'amneziawg']]) {
    assert.equal(transports.availableVpnTransportPreference(input,available),output);
  }
});

function actualAvailability(values) {
  const file=path.join(root,'src/vpn/useVpnConnection.ts'), source=fs.readFileSync(file,'utf8');
  const tree=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let expression;
  function visit(n){if(ts.isVariableDeclaration(n)&&n.name.getText(tree)==='supportsVless')expression=n.initializer.getText(tree);ts.forEachChild(n,visit);}visit(tree);
  assert.ok(expression,'the real hook must derive server availability');
  const context={supportsNativeVless:()=>true,locationsRefreshError:null,locationsData:[ready],vlessCatalog:[ready],serverSelectionMode:'manual',selectedLocationId:'fi',hasAvailableVlessLocation:servers.hasAvailableVlessLocation,...values};
  return new Function(...Object.keys(context),`return (${expression})`)(...Object.values(context));
}
test('the actual hook hides VLESS on missing/failed catalog and restores it on a fresh positive response', () => {
  assert.equal(actualAvailability(),true);
  assert.equal(actualAvailability({supportsNativeVless:()=>false}),false);
  assert.equal(actualAvailability({vlessCatalog:null}),false);
  assert.equal(actualAvailability({locationsRefreshError:new Error('offline')}),false);
  assert.equal(actualAvailability({vlessCatalog:[{...ready,capabilities:[]}]}),false);
  assert.equal(actualAvailability({vlessCatalog:[ready]}),true);
  const source=fs.readFileSync(path.join(root,'src/vpn/useVpnConnection.ts'),'utf8');
  assert.match(source,/supportsVless,\s*unavailableTransportMessage:/);
  assert.match(source,/availableVpnTransportPreference\(preferredTransport, supportsVless\)/);
  assert.match(source,/if \(next === 'vless' && !supportsVless\) throw/);
});

function nodes(tree){return !tree||typeof tree!=='object'?[]:[tree,...[tree.props?.children].flat(Infinity).flatMap(nodes)];}
function settings(supportsVless,transport='auto',unavailableTransportMessage=null,overrides={}) {
  const iconNames=['Check','ChevronRight','ChevronLeft','CreditCard','FlaskConical','Globe2','Languages','LogOut','MessageSquare','Power','RefreshCw','ServerCog','Smartphone'];
  const bindings={...Object.fromEntries(iconNames.map(n=>[n,n])),React:{...React,useState:v=>[v,()=>{}],useCallback:f=>f},
    Alert:{alert:()=>{}},playSelectionHaptic:()=>{},Platform:{OS:'android'},StyleSheet:{create:s=>s,hairlineWidth:1},ScrollView:'ScrollView',Text:'Text',View:'View',Host:'Host',ExpoSwitch:'ExpoSwitch',
    VexScreen:'VexScreen',VexSection:'VexSection',VexPressable:'VexPressable',ServiceNotice:'ServiceNotice',
    vexColors:loadModule('src/ui/vex-theme.ts').vexTheme.colors,vexSharedStyles:{},useFocusEffect:()=>{},useToast:()=>({showToast:()=>{}}),
    useVexSettings:()=>({appInfo:{},remoteConfig:null,isAutomationEnabled:false,isAutoServerSelectionEnabled:false,isAntiLeakEnabled:true}),
    useVpnConnectionContext:()=>({supportsVless,transport,unavailableTransportMessage,vpnStatus:{state:'disconnected'},trafficQuota:{},accountSummaryText:'fixture',isSmartRoutingEnabled:true}),
    ...overrides,
  };
  const module=loadModule('src/screens/settings-screen.tsx',{'react/jsx-runtime':require('react/jsx-runtime')},{},bindings);
  return nodes(module.default());
}
test('real settings remove the VLESS control and VLESS routing hint, then bring the control back', () => {
  for (const available of [false,true,false]) {
    const tree=settings(available);
    assert.equal(tree.some(n=>n.props?.testID==='settings-protocol-vless'),available);
    assert.ok(tree.some(n=>n.props?.testID==='settings-protocol-auto'));
    assert.ok(tree.some(n=>n.props?.testID==='settings-protocol-amneziawg'));
    if(!available)assert.doesNotMatch(tree.filter(n=>n.type==='Text').map(n=>n.props.children).flat(Infinity).join(' '),/VLESS/);
  }
});

test('unavailable saved VLESS choice explains the effective Auto mode in real settings', () => {
  const message='VLESS сейчас недоступен. Используется режим «Авто».';
  const tree=settings(false,'auto',message);
  assert.equal(tree.some(n=>n.props?.testID==='settings-protocol-vless'),false);
  assert.equal(tree.find(n=>n.props?.testID==='settings-protocol-auto').props.accessibilityState.checked,true);
  assert.ok(tree.some(n=>n.props?.accessibilityRole==='alert'&&n.props.children===message));
});

test('an empty latest server response withdraws VLESS even while AWG retains its previous catalog', () => {
  assert.equal(actualAvailability({locationsData:[ready],vlessCatalog:[]}),false);
});

test('the real catalog fetch publishes empty capability data and fences obsolete sessions', async () => {
  const file=path.join(root,'src/vpn/useVpnConnection.ts'),source=fs.readFileSync(file,'utf8');
  const tree=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);let expression;
  function visit(n){if(ts.isVariableDeclaration(n)&&n.name.getText(tree)==='fetchVpnLocations')expression=n.initializer.getText(tree);ts.forEachChild(n,visit);}visit(tree);
  let response=[ready],current=true;const writes=[];
  const context={useCallback:f=>f,accessToken:'fixture',vpnLocations:async()=>response,isCurrentSessionOperation:()=>current,setVlessCatalog:value=>writes.push(value)};
  const code=ts.transpileModule(`return (${expression});`,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
  const fetch=new Function(...Object.keys(context),code)(...Object.values(context));
  await fetch();response=[];await fetch();assert.deepEqual(writes,[[ready],[]]);
  current=false;response=[ready];await fetch();assert.deepEqual(writes,[[ready],[]]);
  current=true;const controller=new AbortController();controller.abort();
  await fetch({signal:controller.signal});assert.deepEqual(writes,[[ready],[]],'cancelled Query result cannot restore VLESS availability');
});

function visibleSettingsText(tree) {
  return tree.filter(n=>n.type==='Text').flatMap(n=>[n.props.children].flat(Infinity)).filter(v=>typeof v==='string').join(' ');
}

test('settings are concise without repeating the switch state in visible copy', () => {
  const tree=settings(false), text=visibleSettingsText(tree);
  assert.doesNotMatch(text,/Включено|Выключено|Без переключений ради замера|Направлять через туннель/);
  assert.ok(text.length<750,`visible copy must stay compact: ${text.length}`);
  const switches=tree.filter(n=>n.type==='VexPressable'&&n.props.accessibilityRole==='switch');
  assert.deepEqual(switches.map(n=>n.props.accessibilityState.checked),[false,false,true,true]);
  assert.ok(switches.every(n=>n.props.accessibilityLabel));
  assert.equal(tree.find(n=>n.props.testID==='settings-protocol-auto').props.accessibilityState.checked,true);
});

test('boot protection retains its full warning on demand, before opening Android settings', async () => {
  const dialogs=[];let opened=0;
  const tree=settings(false,'auto',null,{Alert:{alert:(...args)=>dialogs.push(args)},openVpnSettings:async()=>{opened++;return true;}});
  const row=tree.find(n=>n.props.accessibilityLabel==='Настроить защиту VPN при загрузке');
  row.props.onPress();assert.equal(opened,0);assert.equal(dialogs.length,1);
  const [title,message,buttons]=dialogs[0];assert.equal(title,'Постоянная VPN');
  assert.match(message,/Постоянная VPN/);assert.match(message,/Блокировать соединения без VPN/);
  assert.match(message,/Исключённые приложения тоже будут заблокированы/);
  assert.match(message,/Отключить эту защиту можно в настройках Android/);
  assert.equal(buttons[0].style,'cancel');assert.equal(buttons[0].onPress,undefined);
  await buttons[1].onPress();assert.equal(opened,1);
});

test('boot settings errors remain visible rather than swallowing a failed native open', async () => {
  const dialogs=[],toasts=[];
  const tree=settings(false,'auto',null,{Alert:{alert:(...a)=>dialogs.push(a)},openVpnSettings:async()=>false,useToast:()=>({showToast:t=>toasts.push(t)})});
  tree.find(n=>n.props.accessibilityLabel==='Настроить защиту VPN при загрузке').props.onPress();
  await dialogs[0][2][1].onPress();assert.equal(toasts[0].variant,'error');
});

test('short copy retains connected-state and VLESS routing limitations', () => {
  const tree=settings(true,'vless',null,{useVpnConnectionContext:()=>({supportsVless:true,transport:'vless',vpnStatus:{state:'connected',transport:'vless'},isSmartRoutingEnabled:true})});
  const text=visibleSettingsText(tree);
  assert.match(text,/После переподключения/);assert.match(text,/UDP/);assert.match(text,/умный режим/i);
  assert.equal(tree.find(n=>n.props.accessibilityLabel==='Умный режим'&&n.type==='VexPressable').props.accessibilityState.disabled,true);
});
