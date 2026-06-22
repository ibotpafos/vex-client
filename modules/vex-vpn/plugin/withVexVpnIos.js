const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { withDangerousMod, withEntitlementsPlist } = require('@expo/config-plugins');

const appGroup = 'group.com.vexguard.app';
const packetTunnelProvider = 'packet-tunnel-provider';

module.exports = function withVexVpnIos(config) {
  config = withEntitlementsPlist(config, (mod) => {
    mod.modResults['com.apple.developer.networking.networkextension'] = [packetTunnelProvider];
    mod.modResults['com.apple.security.application-groups'] = [appGroup];
    return mod;
  });

  return withDangerousMod(config, [
    'ios',
    (mod) => {
      const scriptPath = path.resolve(mod.modRequest.projectRoot, '..', 'scripts', 'ios_sync_vpn_extension.rb');
      const result = spawnSync('ruby', [scriptPath], {
        cwd: path.resolve(mod.modRequest.projectRoot, '..'),
        encoding: 'utf8',
        stdio: 'pipe',
      });

      if (result.status !== 0) {
        throw new Error(`Failed to sync VEX VPN iOS extension:\n${result.stdout}${result.stderr}`);
      }
      if (result.stdout.trim()) {
        console.log(result.stdout.trim());
      }
      return mod;
    },
  ]);
};
