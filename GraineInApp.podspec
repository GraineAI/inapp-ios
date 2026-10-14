# GraineInApp for apps that still install with a Podfile.
#
# Swift Package Manager (Package.swift) is the primary install. This spec builds
# exactly what the Swift package builds: the same sources, iOS 15, Swift 5.9
# and the privacy manifest. The version is read from Version.swift, the one
# place it is written, so the pod and the package can never disagree.
version = File.read(File.join(__dir__, "Sources", "GraineInApp", "Version.swift"))[/static let name = "([^"]+)"/, 1]
raise "Sources/GraineInApp/Version.swift does not say which version this is" unless version

Pod::Spec.new do |s|
  s.name              = "GraineInApp"
  s.version           = version
  s.summary           = "An AI agent inside your iOS app: it sees the screen, acts in the app, shows components and talks."
  s.description       = <<~DESC
    The Graine in-app agent for native iOS, in Swift with no dependencies. The
    agent sees the screen your app describes, acts through the actions you
    register, draws components such as product lists, choices and time slots,
    and talks by voice. Native calls run on CallKit and VoIP pushes.
  DESC
  s.homepage          = "https://www.graine.ai/docs/in-app/ios"
  s.documentation_url = "https://www.graine.ai/docs/in-app/ios"
  s.license           = { :type => "MIT", :file => "LICENSE" }
  s.author            = { "Graine AI" => "support@graine.ai" }
  # The tag publish-sdk-repo.sh pushes for this version.
  s.source            = { :git => "https://github.com/GraineAI/inapp-ios.git", :tag => s.version.to_s }

  s.ios.deployment_target = "15.0"
  s.swift_versions    = ["5.9"]

  s.source_files      = "Sources/GraineInApp/**/*.swift"
  # The privacy manifest: the required-reason APIs the SDK calls, for the app's
  # privacy report. Its own bundle, as Apple asks of CocoaPods SDKs.
  s.resource_bundles  = { "GraineInApp_Privacy" => ["Sources/GraineInApp/PrivacyInfo.xcprivacy"] }
  s.frameworks        = "AVFoundation", "CallKit", "Combine", "CoreGraphics", "CoreText", "PushKit", "SwiftUI", "UIKit", "WebKit"
end
