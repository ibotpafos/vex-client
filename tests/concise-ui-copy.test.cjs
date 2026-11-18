const assert = require('node:assert/strict');
const test = require('node:test');
const React = require('react');
const { loadModule } = require('./vpn-module-loader.cjs');
const nodes = tree => !tree || typeof tree !== 'object' ? [] : [tree, ...[tree.props?.children].flat(Infinity).flatMap(nodes)];
const text = tree => nodes(tree).filter(n => n.type === 'Text').flatMap(n => [n.props.children].flat(Infinity)).filter(v => typeof v === 'string').join(' ');
const bindings = { Host:'Host', Column:'Column', List:'List', ListItem:'ListItem', Button:'Button', Text:'Text', TextInput:'TextInput', Spacer:'Spacer', View:'View', StyleSheet:{ create:s=>s }, vexColors:{} };
const load = (file, extra={}) => loadModule(file, { 'react/jsx-runtime':require('react/jsx-runtime') }, {}, { ...bindings, ...extra });
const applications = (extra={}) => load('src/components/universal-vpn-applications-content.tsx').UniversalVpnApplicationsContent({ applications:[],loading:false,mode:'all',selectedPackages:new Set(),...extra });

test('app routing keeps a short instruction and removes filler loading copy', () => {
  const tree=applications({loading:true}), instruction=nodes(tree).find(n=>n.type==='Text').props.children.trim();
  assert.ok(instruction.length<=32,instruction);
  assert.equal(nodes(tree).find(n=>n.props.children==='Загружаем приложения…').props.supportingText,undefined);
  assert.ok(nodes(tree).some(n=>n.props.placeholder==='Поиск приложений'));
});

test('shorter app copy preserves all/selected modes and per-package callbacks', () => {
  const calls=[]; const tree=applications({applications:[{packageName:'fixture.app',label:'Fixture'}],selectedPackages:new Set(['fixture.app']),onModeChange:m=>calls.push(m),onToggleApplication:p=>calls.push(p)});
  nodes(tree).find(n=>n.props.label==='Все приложения').props.onPress();
  nodes(tree).find(n=>n.props.label==='Выбранные (1)').props.onPress();
  const row=nodes(tree).find(n=>n.props.testID==='vpn-application-fixture.app');
  assert.equal(row.props.supportingText,'fixture.app');assert.equal(row.props.trailing,'VPN');row.props.onPress();
  assert.deepEqual(calls,['all','selected','fixture.app']);
});

test('short service notices distinguish stale evidence from unknown status', () => {
  for(const [message,expected] of [['Работы',/восстановление не подтверждено/],[null,/Статус неизвестен/]]){
    const tree=load('src/components/service-notice.tsx',{useServiceNotice:()=>({notice:{title:'Статус VEX',message,unavailable:true}})}).ServiceNotice();
    assert.equal(tree.props.accessibilityRole,'alert');assert.equal(tree.props.accessibilityLiveRegion,'polite');
    const copy=text(tree);assert.match(copy,expected);assert.ok(copy.length<=140,copy);
    if(message) assert.match(copy,/Работы/);
  }
});

test('renewal copy stays short without invented prices or loss of website and support paths', () => {
  const {subscriptionRenewalPresentation:present}=loadModule('src/screens/subscription-renewal-presentation.ts');
  const now=Date.parse('2026-11-17T00:00:00Z');
  const expired=present({active:false,vpnAccess:false,effectiveExpiresAt:'2026-11-16T00:00:00Z'},now);
  assert.ok(expired.message.length<=70,expired.message);assert.match(expired.message,/подписку/);assert.match(expired.message,/сайте/);
  const ending=present({active:true,vpnAccess:true,effectiveExpiresAt:'2026-11-17T12:00:00Z'},now);
  assert.match(ending.message,/17 ноября/);assert.match(ending.message,/сайте/);assert.equal(ending.action,'Продлить VPN');
  assert.doesNotMatch(JSON.stringify([expired,ending]),/199|499|бесплатно/i);
});

function nativePicker(busy=false) {
  const item=Object.assign(props=>React.createElement('ComposeListItem',props),{
    LeadingContent:'LeadingContent',HeadlineContent:'HeadlineContent',SupportingContent:'SupportingContent',TrailingContent:'TrailingContent',
  });
  const {ServerPickerContent}=load('src/components/server-picker-modal.tsx',{
    React:{...React,memo:f=>f,useMemo:f=>f(),useState:v=>[v,()=>{}]},UniversalText:'Text',ComposeText:'Text',ComposeListItem:item,
    clickable:onClick=>({onClick}),composeTestID:testID=>({testID}),
  });
  function expand(t){
    if(Array.isArray(t))return t.map(expand);
    if(!t||typeof t!=='object')return t;
    if(typeof t.type==='function')return expand(t.type(t.props));
    return {...t,props:{...t.props,children:expand(t.props.children)}};
  }
  const calls=[];
  const tree=expand(ServerPickerContent({isVpnBusy:busy,locations:[{id:'fi',city:'Helsinki',countryCode:'FI',availability:'available',status:'healthy',healthyNodes:1,awg3Nodes:1,latencyMs:8}],selectionMode:'manual',selectedLocationId:'fi',onAutoSelect:()=>calls.push('auto'),onSelect:id=>calls.push(id)}));
  const row=id=>nodes(tree).find(n=>n.type==='ComposeListItem'&&n.props.modifiers.some(m=>m.testID===id));
  return {tree,calls,row};
}

test('native picker has one compact heading and preserves auto/manual callbacks', () => {
  const {tree,calls,row}=nativePicker();const copy=text(tree);
  assert.doesNotMatch(copy,/Оставьте автовыбор|Локация/);assert.match(copy,/Серверы/);assert.match(copy,/8 мс/);
  row('server-picker-auto').props.modifiers.find(m=>m.onClick).onClick();
  row('server-picker-country-fi').props.modifiers.find(m=>m.onClick).onClick();
  assert.deepEqual(calls,['auto','fi']);
});

test('concise picker does not reenable selection during a VPN operation', () => {
  const {row}=nativePicker(true);
  for(const id of ['server-picker-auto','server-picker-country-fi']) assert.equal(row(id).props.modifiers.some(m=>m.onClick),false);
});

test('shared update assessment uses short copy without relaxing installation or recovery policy', () => {
  const {assessManualUpdateCenter:assess}=loadModule('src/api/updatePreflight.ts',{}, {}, {productionApiOrigins:['https://vexguard.app'],trustedUpdateBaseUrl:'https://vexguard.app'});
  const base={currentBuild:1,currentVersion:'1.0.0',trustedBaseUrl:'https://vexguard.app'};
  const ready={updateAvailable:true,required:true,latestVersion:'1.0.1',latestBuild:2,minSupportedBuild:1,downloadUrl:'https://vexguard.app/downloads/fixture.apk',checksumSha256:'a'.repeat(64),signatureUrl:'https://vexguard.app/downloads/fixture.apk.sig'};
  assert.equal(assess(base).message,'Версия совместима с сервером.');
  for(const reason of ['blocked_release','android_signing_key_migration','unsupported_config_schema','core_version_unsupported','api_client_version_unsupported']) {
    const result=assess({...base,update:{...ready,reason,currentBuildBlocked:reason==='blocked_release'}});
    assert.ok(result.message.length<=110,result.message);assert.equal(result.required,true);assert.equal(result.updateAvailable,true);assert.equal(result.canInstall,true);
    assert.equal(result.currentBuildBlocked,reason==='blocked_release');
    if(reason==='android_signing_key_migration')assert.match(result.message,/отдельно.*Войдите.*проверьте доступ.*удалите/);
    if(reason==='blocked_release')assert.match(result.message,/заблокирована.*стабильную/);
    const denied=assess({...base,update:{...ready,reason,downloadUrl:'https://foreign.invalid/fixture.apk'}});
    assert.equal(denied.canInstall,false);assert.equal(denied.preflight.ok,false);
  }
});
