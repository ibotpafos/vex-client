#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

ROOT_DIR = File.expand_path('..', __dir__)
IOS_DIR = File.join(ROOT_DIR, 'ios')
PROJECT_PATH = File.join(IOS_DIR, 'VEX.xcodeproj')

APP_TARGET_NAME = 'VEX'
EXTENSION_TARGET_NAME = 'VexLiveActivityWidgetExtension'
EXTENSION_BUNDLE_IDENTIFIER = 'com.vexguard.app.liveactivity'
DEVELOPMENT_TEAM = ENV.fetch('IOS_DEVELOPMENT_TEAM', '').strip
EXTENSION_SOURCE_ROOT = '../modules/vex-live-activity-widget/ios'
EXTENSION_INFO_PLIST = "#{EXTENSION_SOURCE_ROOT}/Info.plist"
EXTENSION_ENTITLEMENTS = "#{EXTENSION_SOURCE_ROOT}/VexLiveActivityWidget.entitlements"
SHARED_SOURCE_ROOT = '../modules/vex-vpn/ios/live-activity'
WIDGET_SOURCE = 'VexLiveActivityWidget.swift'
ATTRIBUTES_SOURCE = 'VexVpnActivityAttributes.swift'

def fail_with(message)
  warn "error: #{message}"
  exit 1
end

def build_setting(target, key)
  target.build_configurations.map { |configuration| configuration.build_settings[key] }.compact.first
end

def find_or_create_group(project, name, path)
  group = project.main_group.children.find { |child| child.display_name == name }
  return group if group

  project.main_group.new_group(name, path)
end

def find_or_create_file(group, path)
  group.files.find { |file| file.path == path } || group.new_file(path)
end

def find_or_create_extension_target(project)
  project.targets.find { |target| target.name == EXTENSION_TARGET_NAME } ||
    project.new_target(:app_extension, EXTENSION_TARGET_NAME, :ios, '16.4')
end

def configured_development_team(app_target)
  return DEVELOPMENT_TEAM unless DEVELOPMENT_TEAM.empty?

  build_setting(app_target, 'DEVELOPMENT_TEAM')
end

def configure_extension_target(target, app_target)
  development_team = configured_development_team(app_target)
  marketing_version = build_setting(app_target, 'MARKETING_VERSION') || '1.0'
  current_project_version = build_setting(app_target, 'CURRENT_PROJECT_VERSION') || '1'

  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['CODE_SIGN_ENTITLEMENTS'] = "$(SRCROOT)/#{EXTENSION_ENTITLEMENTS}"
    settings['CURRENT_PROJECT_VERSION'] = current_project_version
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['INFOPLIST_FILE'] = "$(SRCROOT)/#{EXTENSION_INFO_PLIST}"
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.4'
    settings['MARKETING_VERSION'] = marketing_version
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXTENSION_BUNDLE_IDENTIFIER
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['SKIP_INSTALL'] = 'YES'
    settings['SWIFT_VERSION'] ||= '5.0'
    settings['TARGETED_DEVICE_FAMILY'] ||= '1,2'
    settings['DEVELOPMENT_TEAM'] = development_team if development_team
  end
end

def add_source(target, file_reference)
  return if target.source_build_phase.files_references.include?(file_reference)

  target.source_build_phase.add_file_reference(file_reference)
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

extension_group = find_or_create_group(project, EXTENSION_TARGET_NAME, EXTENSION_SOURCE_ROOT)
shared_group = find_or_create_group(project, 'VexLiveActivityShared', SHARED_SOURCE_ROOT)
widget_file = find_or_create_file(extension_group, WIDGET_SOURCE)
attributes_file = find_or_create_file(shared_group, ATTRIBUTES_SOURCE)
extension_target = find_or_create_extension_target(project)

configure_extension_target(extension_target, app_target)
add_source(extension_target, widget_file)
add_source(extension_target, attributes_file)
add_app_dependency(app_target, extension_target)
embed_extension(app_target, extension_target)

project.save
puts "Synced #{EXTENSION_TARGET_NAME} target in #{PROJECT_PATH}"
