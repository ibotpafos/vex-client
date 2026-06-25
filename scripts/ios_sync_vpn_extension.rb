#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'
require 'shellwords'

ROOT_DIR = File.expand_path('..', __dir__)
IOS_DIR = File.join(ROOT_DIR, 'ios')
PROJECT_PATH = File.join(IOS_DIR, 'VEX.xcodeproj')

APP_TARGET_NAME = 'VEX'
EXTENSION_TARGET_NAME = 'VexVpnTunnel'
EXTENSION_BUNDLE_IDENTIFIER = 'com.vexguard.app.tunnel'
DEVELOPMENT_TEAM = ENV.fetch('IOS_DEVELOPMENT_TEAM', '').strip
EXTENSION_SOURCE_ROOT = '../modules/vex-vpn/ios/tunnel'
EXTENSION_INFO_PLIST = "#{EXTENSION_SOURCE_ROOT}/Info.plist"
EXTENSION_ENTITLEMENTS = "#{EXTENSION_SOURCE_ROOT}/VexVpnTunnel.entitlements"
AMNEZIAWG_PACKAGE_PATH = '../external/amnezia/amneziawg-apple'
STALE_AMNEZIAWG_PACKAGE_PATHS = [
  '../../external/amnezia/amneziawg-apple'
].freeze
AMNEZIAWG_BRIDGE_SCRIPT = '"${SRCROOT}/../scripts/ios_build_amneziawg_bridge.sh"'
AMNEZIAWG_BRIDGE_OUTPUT = '$(SRCROOT)/../external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/out/libwg-go.a'
AMNEZIAWG_BRIDGE_OUTPUT_SHELL = '"${SRCROOT}/../external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/out/libwg-go.a"'
PACKET_TUNNEL_SOURCE = 'PacketTunnelProvider.swift'
WG_QUICK_SOURCE = 'WgQuickTunnelConfiguration.swift'
GO_RUNTIME_SHIM_SOURCE = 'GoRuntimeNoLldbShim.c'
STALE_AMNEZIAWG_MODEL_SOURCES = [
  'String+ArrayConversion.swift',
  'TunnelConfiguration+WgQuickConfig.swift'
].freeze

def fail_with(message)
  warn "error: #{message}"
  exit 1
end

def find_or_create_group(project)
  group = project.main_group.children.find { |child| child.display_name == EXTENSION_TARGET_NAME }
  return group if group

  project.main_group.new_group(EXTENSION_TARGET_NAME, EXTENSION_SOURCE_ROOT)
end

def find_or_create_source_file(group)
  group.files.find { |file| file.path == PACKET_TUNNEL_SOURCE } || group.new_file(PACKET_TUNNEL_SOURCE)
end

def find_or_create_wg_quick_file(group)
  group.files.find { |file| file.path == WG_QUICK_SOURCE } || group.new_file(WG_QUICK_SOURCE)
end

def find_or_create_go_runtime_shim_file(group)
  group.files.find { |file| file.path == GO_RUNTIME_SHIM_SOURCE } || group.new_file(GO_RUNTIME_SHIM_SOURCE)
end

def find_or_create_extension_target(project)
  project.targets.find { |target| target.name == EXTENSION_TARGET_NAME } ||
    project.new_target(:app_extension, EXTENSION_TARGET_NAME, :ios, '16.4')
end

def build_setting(target, key)
  target.build_configurations.map { |configuration| configuration.build_settings[key] }.compact.first
end

def expand_ios_build_path(path)
  return nil if path.nil? || path.empty?

  path
    .gsub('$(SRCROOT)', IOS_DIR)
    .gsub('${SRCROOT}', IOS_DIR)
    .then { |expanded| File.expand_path(expanded, IOS_DIR) }
end

def plist_value(path, key)
  return nil unless path && File.exist?(path)

  value = `/usr/libexec/PlistBuddy -c "Print :#{key}" #{Shellwords.escape(path)} 2>/dev/null`.strip
  value.empty? ? nil : value
end

def app_info_plist_value(app_target, key)
  plist_path = expand_ios_build_path(build_setting(app_target, 'INFOPLIST_FILE'))
  plist_value(plist_path, key)
end

def configured_development_team(app_target)
  return DEVELOPMENT_TEAM unless DEVELOPMENT_TEAM.empty?

  build_setting(app_target, 'DEVELOPMENT_TEAM')
end

def configure_app_target(target)
  return if DEVELOPMENT_TEAM.empty?

  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['DEVELOPMENT_TEAM'] = DEVELOPMENT_TEAM
  end
end

def configure_extension_target(target, app_target)
  marketing_version = app_info_plist_value(app_target, 'CFBundleShortVersionString') ||
                      build_setting(app_target, 'MARKETING_VERSION') ||
                      '1.0'
  current_project_version = app_info_plist_value(app_target, 'CFBundleVersion') ||
                            build_setting(app_target, 'CURRENT_PROJECT_VERSION') ||
                            '1'
  development_team = configured_development_team(app_target)

  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['CODE_SIGN_ENTITLEMENTS'] = "$(SRCROOT)/#{EXTENSION_ENTITLEMENTS}"
    settings['CURRENT_PROJECT_VERSION'] = current_project_version
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['INFOPLIST_FILE'] = "$(SRCROOT)/#{EXTENSION_INFO_PLIST}"
    settings['IPHONEOS_DEPLOYMENT_TARGET'] ||= '16.4'
    settings['MARKETING_VERSION'] = marketing_version
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXTENSION_BUNDLE_IDENTIFIER
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['SKIP_INSTALL'] = 'YES'
    settings['SWIFT_VERSION'] ||= '5.0'
    settings['TARGETED_DEVICE_FAMILY'] ||= '1,2'
    settings['LIBRARY_SEARCH_PATHS'] = [
      '$(inherited)',
      '$(SRCROOT)/../external/amnezia/amneziawg-apple/Sources/WireGuardKitGo/out'
    ]
    settings['DEVELOPMENT_TEAM'] = development_team if development_team
  end
end

def add_source(target, file_reference)
  return if target.source_build_phase.files_references.include?(file_reference)

  target.source_build_phase.add_file_reference(file_reference)
end

def remove_stale_model_sources(target)
  target.source_build_phase.files.dup.each do |build_file|
    next unless STALE_AMNEZIAWG_MODEL_SOURCES.include?(build_file.file_ref&.path)

    target.source_build_phase.remove_build_file(build_file)
  end
end

def find_or_create_package_reference(project)
  project.root_object.package_references.delete_if do |reference|
    reference.respond_to?(:relative_path) &&
      STALE_AMNEZIAWG_PACKAGE_PATHS.include?(reference.relative_path)
  end

  package = project.root_object.package_references.find do |reference|
    reference.respond_to?(:relative_path) && reference.relative_path == AMNEZIAWG_PACKAGE_PATH
  end
  return package if package

  package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package.relative_path = AMNEZIAWG_PACKAGE_PATH
  project.root_object.package_references << package
  package
end

def find_or_create_package_product(project, target, package)
  product = target.package_product_dependencies.find { |dependency| dependency.product_name == 'WireGuardKit' }
  if product
    product.package = package
    return product
  end

  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.product_name = 'WireGuardKit'
  product.package = package
  target.package_product_dependencies << product
  product
end

def link_package_product(target, product)
  return if target.frameworks_build_phase.files.any? { |file| file.product_ref == product }

  build_file = target.project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

def add_bridge_build_phase(target)
  phase = target.shell_script_build_phases.find { |item| item.name == 'Build AmneziaWG bridge' } ||
          target.new_shell_script_build_phase('Build AmneziaWG bridge')
  phase.shell_script = <<~SH
    set -euo pipefail
    if [ ! -f #{AMNEZIAWG_BRIDGE_OUTPUT_SHELL} ]; then
      #{AMNEZIAWG_BRIDGE_SCRIPT}
    fi
  SH
  phase.output_paths = [AMNEZIAWG_BRIDGE_OUTPUT]
  target.build_phases.delete(phase)
  target.build_phases.unshift(phase)
end

def add_app_dependency(app_target, extension_target)
  has_dependency = app_target.dependencies.any? do |dependency|
    dependency.target_proxy&.remote_global_id_string == extension_target.uuid
  end
  app_target.add_dependency(extension_target) unless has_dependency
end

def embed_extension(app_target, extension_target)
  phase = app_target.copy_files_build_phases.find { |item| item.display_name == 'Embed App Extensions' } ||
          app_target.new_copy_files_build_phase('Embed App Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins
  phase.dst_path = ''

  build_file = phase.files.find { |file| file.file_ref == extension_target.product_reference } ||
               phase.add_file_reference(extension_target.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }
end

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |target| target.name == APP_TARGET_NAME } ||
             fail_with("app target #{APP_TARGET_NAME.inspect} is missing in #{PROJECT_PATH}")

extension_group = find_or_create_group(project)
source_file = find_or_create_source_file(extension_group)
wg_quick_file = find_or_create_wg_quick_file(extension_group)
go_runtime_shim_file = find_or_create_go_runtime_shim_file(extension_group)
extension_target = find_or_create_extension_target(project)
package_reference = find_or_create_package_reference(project)
wire_guard_kit = find_or_create_package_product(project, extension_target, package_reference)

configure_app_target(app_target)
configure_extension_target(extension_target, app_target)
remove_stale_model_sources(extension_target)
add_source(extension_target, source_file)
add_source(extension_target, wg_quick_file)
add_source(extension_target, go_runtime_shim_file)
link_package_product(extension_target, wire_guard_kit)
add_bridge_build_phase(extension_target)
add_app_dependency(app_target, extension_target)
embed_extension(app_target, extension_target)

project.save
puts "Synced #{EXTENSION_TARGET_NAME} target in #{PROJECT_PATH}"
