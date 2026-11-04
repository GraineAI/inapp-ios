import Foundation
import Testing
@testable import GraineInApp

/// A bridge asks the facade which iOS SDK the app really linked: Kotlin and Xcode resolve theirs separately.
@Suite struct SdkVersionFacadeTests {
    @Test func theFacadeSaysItsVersionToObjectiveC() throws {
        let cls = try #require(NSClassFromString("GraineObjC") as? NSObject.Type)
        #expect(cls.instancesRespond(to: NSSelectorFromString("sdkVersion")))
    }
}
