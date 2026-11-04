require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)
output = File.join(root, 'Generated')
FileUtils.mkdir_p(output)
bundle = ENV.fetch('SESSION99_BUNDLE_PREFIX', 'net.local.varanha.session99groups')
group = ENV.fetch('SESSION99_APP_GROUP', 'group.net.local.varanha.session99groups')
abort 'Invalid bundle identifier' unless bundle.match?(/\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/)
abort 'Invalid App Group identifier' unless group.match?(/\Agroup\.[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/)

project = Xcodeproj::Project.new(File.join(output, 'Session99Groups.xcodeproj'))
sdk = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sdk.repositoryURL = 'https://github.com/open-telemetry/opentelemetry-swift.git'
sdk.requirement = { 'kind' => 'revision', 'revision' => 'ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a' }
project.root_object.package_references << sdk

host = project.new_target(:application, 'Session99Groups', :ios, '15.0')
extension = project.new_target(:app_extension, 'Session99Share', :ios, '15.0')
tests = project.new_target(:ui_test_bundle, 'Session99GroupsUITests', :ios, '17.0')
[[host, 'Host.swift'], [extension, 'Share.swift'], [tests, 'GroupUITests.swift']].each do |target, source|
  target.add_file_references([project.main_group.new_file("../#{source}")])
  target.add_file_references([project.main_group.new_file('../GroupResult.swift')])
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => target == host ? bundle : "#{bundle}.#{target.name}",
      'SWIFT_VERSION' => '5.0', 'IPHONEOS_DEPLOYMENT_TARGET' => target == tests ? '17.0' : '15.0',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'MARKETING_VERSION' => '1.0', 'CURRENT_PROJECT_VERSION' => '1',
      'CODE_SIGN_STYLE' => 'Manual', 'CODE_SIGN_IDENTITY[sdk=iphonesimulator*]' => '-',
      'CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]' => 'YES'
    })
    next if target == tests
    config.build_settings.merge!({
      'INFOPLIST_FILE' => "#{target.name}-Info.plist",
      'CODE_SIGN_ENTITLEMENTS' => 'AppGroup.entitlements',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    })
    config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES' if target == extension
  end
end
[host, extension].each do |target|
  target.add_file_references([project.main_group.new_file('../GroupProbe.swift')])
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = sdk
  product.product_name = 'Sessions'
  target.package_product_dependencies << product
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = product
  target.frameworks_build_phase.files << build
end
host.add_dependency(extension)
embed = host.new_copy_files_build_phase('Embed App Extension')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(extension.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
tests.add_dependency(host)
tests.build_configurations.each { |config| config.build_settings['TEST_TARGET_NAME'] = host.name }
project.root_object.attributes['TargetAttributes'] = { tests.uuid => { 'TestTargetID' => host.uuid } }

common = { 'Session99AppGroup' => group }
Xcodeproj::Plist.write_to_path(common.merge({ 'CFBundleDisplayName' => 'Session 99 Groups',
  'UIApplicationSceneManifest' => { 'UIApplicationSupportsMultipleScenes' => false,
    'UISceneConfigurations' => {} },
  'UILaunchScreen' => {} }), File.join(output, 'Session99Groups-Info.plist'))
Xcodeproj::Plist.write_to_path(common.merge({ 'CFBundleDisplayName' => 'Session 99 Share',
  'NSExtension' => {
    'NSExtensionPointIdentifier' => 'com.apple.share-services',
    'NSExtensionPrincipalClass' => '$(PRODUCT_MODULE_NAME).ShareController',
    'NSExtensionAttributes' => { 'NSExtensionActivationRule' => { 'NSExtensionActivationSupportsText' => true } }
  } }), File.join(output, 'Session99Share-Info.plist'))
Xcodeproj::Plist.write_to_path({ 'com.apple.security.application-groups' => [group] },
                             File.join(output, 'AppGroup.entitlements'))
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.set_launch_target(host)
scheme.add_test_target(tests)
scheme.save_as(project.path, host.name, true)
resolved = File.join(project.path, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
FileUtils.mkdir_p(File.dirname(resolved))
FileUtils.cp(File.join(root, '../Package.resolved'), resolved)
puts project.path
