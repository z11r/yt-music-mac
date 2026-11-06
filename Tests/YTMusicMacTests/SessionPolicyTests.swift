import Foundation
import Testing
@testable import YTMusicMac

struct SessionPolicyTests {
    @Test func navigationRequiresExactDomainBoundaryAndHTTPS() {
        for address in ["https://music.youtube.com/", "https://accounts.google.com/signin", "https://consent.youtube.com/"] {
            #expect(SessionPolicy.allowsLoginNavigation(URL(string: address)!))
        }
        for address in ["http://music.youtube.com/", "https://youtube.com.evil.example/", "https://evilgoogle.com/",
                        "https://youtube.com@evil.example/", "https://music.youtube.com:8443/", "file:///tmp/login.html"] {
            #expect(!SessionPolicy.allowsLoginNavigation(URL(string: address)!))
        }
    }

    @Test func cookiesAreLimitedToApplicableSecureUnexpiredYouTubeDomains() {
        let now = Date(timeIntervalSince1970: 100)
        func cookie(domain: String, secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "test", .value: "sample", .domain: domain, .path: "/"]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let cookies = [cookie(domain: ".youtube.com"), cookie(domain: "music.youtube.com"),
                       cookie(domain: "accounts.google.com"), cookie(domain: "youtube.com.evil.example"),
                       cookie(domain: ".youtube.com", secure: false),
                       cookie(domain: ".youtube.com", expires: now.addingTimeInterval(-1))]
        #expect(SessionPolicy.musicCookies(cookies, now: now).count == 2)
    }
}
