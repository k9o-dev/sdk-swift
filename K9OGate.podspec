Pod::Spec.new do |s|
  s.name             = 'K9OGate'
  s.version          = '1.3.0'
  s.summary          = 'Kilimanjaro Gate SDK for iOS and macOS.'
  s.description      = <<-DESC
    K9OGate is the iOS/macOS Swift SDK for the Kilimanjaro Gate
    Identity-Aware Kernel. Provides sign-in, token refresh, sign-out,
    and secure Keychain-backed refresh-token persistence.
  DESC
  s.homepage         = 'https://kilimanjaro.dev'
  s.documentation_url = 'https://docs.kilimanjaro.dev'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Kilimanjaro' => 'support@kilimanjaro.dev' }
  s.source           = { :git => 'https://github.com/k9o-dev/sdk-swift.git', :tag => s.version.to_s }
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/K9OGate/**/*.swift'
  s.frameworks       = 'Foundation', 'Security'
end
