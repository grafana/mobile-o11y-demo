require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)
project = Xcodeproj::Project.new(File.join(root, 'Session99Probe.xcodeproj'))
target = project.new_target(:application, 'Session99Probe', :ios, '15.0')
target.add_file_references([project.main_group.new_file('Sources/Session99Probe/Probe.swift')])
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '../grafana-opentelemetry-ios'
project.root_object.package_references << package
sdk = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sdk.repositoryURL = 'https://github.com/open-telemetry/opentelemetry-swift.git'
sdk.requirement = { 'kind' => 'revision', 'revision' => 'ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a' }
project.root_object.package_references << sdk
%w[GrafanaOpenTelemetryIOS Sessions].each do |name|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.product_name = name
  product.package = sdk if name == 'Sessions'
  target.package_product_dependencies << product
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = product
  target.frameworks_build_phase.files << build
end
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'net.local.varanha.session99',
    'SWIFT_VERSION' => '5.0',
    'INFOPLIST_FILE' => 'Info.plist',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'IPHONEOS_DEPLOYMENT_TARGET' => '15.0'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path, 'Session99Probe', true)
resolved = File.join(project.path, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
FileUtils.mkdir_p(File.dirname(resolved))
FileUtils.cp(File.join(root, 'Package.resolved'), resolved)
