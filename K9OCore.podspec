Pod::Spec.new do |s|
  s.name             = 'K9OCore'
  s.version          = '1.3.0'
  s.summary          = 'Kilimanjaro project-plane core client for iOS and macOS.'
  s.description      = <<-DESC
    K9OCore is the minimal iOS/macOS Swift client for the Kilimanjaro
    project plane. It currently exposes ai.embed.
  DESC
  s.homepage         = 'https://kilimanjaro.dev'
  s.documentation_url = 'https://docs.kilimanjaro.dev'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Kilimanjaro' => 'support@kilimanjaro.dev' }
  s.source           = { :git => 'https://github.com/k9o-dev/sdk-swift.git', :tag => s.version.to_s }
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/K9OCore/**/*.swift'
  s.frameworks       = 'Foundation'
end
