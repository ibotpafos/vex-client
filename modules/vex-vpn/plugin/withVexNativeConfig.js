const fs = require('node:fs');
const path = require('node:path');
const {
  AndroidConfig,
  withAndroidManifest,
  withDangerousMod,
} = require('@expo/config-plugins');

const androidPermissions = [
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED',
  'android.permission.POST_NOTIFICATIONS',
  'android.permission.REQUEST_INSTALL_PACKAGES',
];

const notificationChannelMetaName = 'com.google.firebase.messaging.default_notification_channel_id';
const networkSecurityConfigResource = '@xml/network_security_config';
const updatesMetaData = {
  'expo.modules.updates.ENABLED': '${vexUpdatesEnabled}',
  'expo.modules.updates.ENABLE_BSDIFF_PATCH_SUPPORT': 'true',
  'expo.modules.updates.EXPO_RUNTIME_VERSION': '${vexRuntimeVersion}',
  'expo.modules.updates.EXPO_UPDATE_URL': '${vexUpdatesUrl}',
  'expo.modules.updates.UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY': '${vexUpdatesRequestHeaders}',
  'expo.modules.updates.CODE_SIGNING_CERTIFICATE': '${vexUpdatesCodeSigningCertificate}',
  'expo.modules.updates.CODE_SIGNING_METADATA': '${vexUpdatesCodeSigningMetadata}',
  'expo.modules.updates.EXPO_UPDATES_CHECK_ON_LAUNCH': 'ALWAYS',
  'expo.modules.updates.EXPO_UPDATES_LAUNCH_WAIT_MS': '0',
};

module.exports = function withVexNativeConfig(config, props = {}) {
  const authScheme = props.authScheme || 'vexguard';
  const notificationChannelId = props.notificationChannelId || 'vex_updates';

  config = AndroidConfig.Permissions.withPermissions(config, androidPermissions);
  config = withAndroidManifest(config, (mod) => {
    const manifest = mod.modResults.manifest;
    const application = getMainApplication(manifest);
    application.$['android:networkSecurityConfig'] = networkSecurityConfigResource;

    upsertMetaData(application, notificationChannelMetaName, notificationChannelId);
    Object.entries(updatesMetaData).forEach(([name, value]) => upsertMetaData(application, name, value));
    upsertLauncherApplicationQuery(manifest);
    upsertVpnServices(application);
    upsertMainActivityIntentFilters(application, authScheme);

    return mod;
  });

  return withDangerousMod(config, [
    'android',
    (mod) => {
      const resXmlDir = path.join(mod.modRequest.platformProjectRoot, 'app/src/main/res/xml');
      fs.mkdirSync(resXmlDir, { recursive: true });
      fs.writeFileSync(path.join(resXmlDir, 'network_security_config.xml'), networkSecurityConfigXml(), 'utf8');
      return mod;
    },
  ]);
};

function getMainApplication(manifest) {
  const application = manifest.application?.[0];
  if (!application) {
    throw new Error('AndroidManifest.xml is missing the main <application> node.');
  }
  return application;
}

function upsertLauncherApplicationQuery(manifest) {
  manifest.queries = manifest.queries || [{ intent: [] }];
  const queries = manifest.queries[0];
  queries.intent = queries.intent || [];
  const exists = queries.intent.some((intent) =>
    intent.action?.some((action) => action.$?.['android:name'] === 'android.intent.action.MAIN') &&
    intent.category?.some((category) => category.$?.['android:name'] === 'android.intent.category.LAUNCHER'));
  if (exists) {
    return;
  }
  queries.intent.push({
    action: [{ $: { 'android:name': 'android.intent.action.MAIN' } }],
    category: [{ $: { 'android:name': 'android.intent.category.LAUNCHER' } }],
  });
}

function upsertMetaData(application, name, value) {
  application['meta-data'] = application['meta-data'] || [];
  const existing = application['meta-data'].find((item) => item.$?.['android:name'] === name);
  const next = { 'android:name': name, 'android:value': value };
  if (existing) {
    existing.$ = { ...existing.$, ...next };
    return;
  }
  application['meta-data'].push({ $: next });
}

function upsertVpnServices(application) {
  application.service = application.service || [];
  upsertService(application.service, {
    name: 'org.amnezia.awg.backend.GoBackend$VpnService',
    exported: 'false',
    foregroundServiceType: 'systemExempted',
    permission: 'android.permission.BIND_VPN_SERVICE',
    action: 'android.net.VpnService',
    metaData: {
      'android:name': 'android.net.VpnService.SUPPORTS_ALWAYS_ON',
      'android:value': 'false',
    },
  });
  upsertService(application.service, {
    name: '.vpn.VexLeakBlockerService',
    exported: 'false',
    foregroundServiceType: 'systemExempted',
    permission: 'android.permission.BIND_VPN_SERVICE',
    action: 'android.net.VpnService',
    metaData: {
      'android:name': 'android.net.VpnService.SUPPORTS_ALWAYS_ON',
      'android:value': 'false',
    },
  });
  upsertService(application.service, {
    name: '.vpn.VexFirebaseMessagingService',
    exported: 'false',
    action: 'com.google.firebase.MESSAGING_EVENT',
  });
}

function upsertService(services, service) {
  let target = services.find((item) => item.$?.['android:name'] === service.name);
  if (!target) {
    target = { $: {} };
    services.push(target);
  }
  target.$ = {
    ...target.$,
    'android:name': service.name,
    'android:exported': service.exported,
  };
  if (service.permission) {
    target.$['android:permission'] = service.permission;
  }
  if (service.foregroundServiceType) {
    target.$['android:foregroundServiceType'] = service.foregroundServiceType;
  }
  target['intent-filter'] = [{ action: [{ $: { 'android:name': service.action } }] }];
  if (service.metaData) {
    target['meta-data'] = [{ $: service.metaData }];
  }
  if (!service.property) {
    delete target.property;
  }
}

function upsertMainActivityIntentFilters(application, authScheme) {
  const mainActivity = application.activity?.find((activity) => activity.$?.['android:name'] === '.MainActivity');
  if (!mainActivity) {
    throw new Error('AndroidManifest.xml is missing .MainActivity.');
  }

  mainActivity['intent-filter'] = (mainActivity['intent-filter'] || [])
    .filter((filter) => !hasDataScheme(filter, 'vex') && !hasDataScheme(filter, authScheme) && !hasHttpsAppLink(filter));

  mainActivity['intent-filter'].push(authCallbackIntentFilter(authScheme));
}

function hasDataScheme(intentFilter, scheme) {
  return (intentFilter.data || []).some((data) => data.$?.['android:scheme'] === scheme);
}

function hasHttpsAppLink(intentFilter) {
  return (intentFilter.data || []).some((data) => data.$?.['android:scheme'] === 'https');
}

function authCallbackIntentFilter(authScheme) {
  return {
    action: [{ $: { 'android:name': 'android.intent.action.VIEW' } }],
    category: [
      { $: { 'android:name': 'android.intent.category.DEFAULT' } },
      { $: { 'android:name': 'android.intent.category.BROWSABLE' } },
    ],
    data: [{ $: { 'android:scheme': authScheme, 'android:host': 'auth', 'android:pathPrefix': '/callback' } }],
  };
}

function networkSecurityConfigXml() {
  return `<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="false" />
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">94.141.160.212</domain>
  </domain-config>
</network-security-config>
`;
}
