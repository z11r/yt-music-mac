import Foundation
import Testing
@testable import YTMusicMac

@Test func developmentIdentityIsSeparate() {
    #expect(AppIdentity.debugIdentifier != AppIdentity.releaseIdentifier)
    #expect(AppIdentity.identifier.hasPrefix("io.github.z11r.ytmusicmac"))
    #expect(!AppIdentity.identifier.contains("kaset"))
}
