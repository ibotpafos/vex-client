Pod::Spec.new do |s|
  s.name           = 'VexVpn'
  s.version        = '1.0.0'
  s.summary        = 'VEX iOS VPN bridge'
  s.description    = 'Expo native module that bridges VEX React Native code to the iOS VPN implementation.'
  s.author         = 'VEX'
  s.homepage       = 'https://vexguard.app'
  s.platforms      = {
    :ios => '16.4'
  }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = [
    "VexVpnModule.swift",
    "live-activity/*.swift"
  ]
end
