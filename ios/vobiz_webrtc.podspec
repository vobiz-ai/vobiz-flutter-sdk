#
# iOS side of vobiz_webrtc: Vobiz push-to-wake over PushKit, the CallKit call
# screen, and WebRTC's audio around CallKit. See VobizIosPush in Dart.
#
Pod::Spec.new do |s|
  s.name             = 'vobiz_webrtc'
  s.version          = '0.3.0'
  s.summary          = 'Vobiz voice calls for Flutter: PushKit and CallKit on iOS.'
  s.description      = <<-DESC
Rings a closed iOS app for Vobiz calls: PushKit VoIP pushes reported to CallKit,
and WebRTC audio started when CallKit activates the audio session.
Downloaded by pub (not CocoaPods).
                       DESC
  s.homepage         = 'https://vobiz.ai'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Vobiz' => 'support@vobiz.ai' }
  s.source           = { :http => 'https://github.com/vobiz-ai/vobiz-flutter-sdk' }
  s.source_files     = 'vobiz_webrtc/Sources/vobiz_webrtc/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'CallKit', 'PushKit', 'AVFoundation', 'CryptoKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.resource_bundles = { 'vobiz_webrtc_privacy' => ['vobiz_webrtc/Sources/vobiz_webrtc/PrivacyInfo.xcprivacy'] }
end
