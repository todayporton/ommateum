import Foundation
import Testing
@testable import Ommateum

struct AppURLTests {
    @Test func roundTripKeepsSeparatorsAndJapanese() {
        for value in [AppURL.open(path: "/Users/me/A&B=C+D #1?/書類"), .workspace(name: "作業 A&B")] {
            #expect(AppURL(value.url) == value)
        }
    }

    @Test func format() {
        #expect(AppURL.workspace(name: "作業A").url.absoluteString == "ommateum://workspace?name=%E4%BD%9C%E6%A5%ADA")
        #expect(AppURL.open(path: "/tmp/a b").url.absoluteString == "ommateum://open?path=/tmp/a%20b")
    }

    @Test func parsing() {
        #expect(AppURL(URL(string: "ommateum://open?path=~/Documents")!) == .open(path: NSHomeDirectory() + "/Documents"))
        #expect(AppURL(URL(string: "OMMATEUM://Workspace?name=x")!) == .workspace(name: "x"))
        #expect(AppURL(URL(string: "ommateum://open")!) == .newWindow)
        #expect(AppURL(URL(string: "ommateum://open?path=")!) == .newWindow)
        #expect(AppURL(AppURL.newWindow.url) == .newWindow)
        #expect(AppURL(URL(string: "ommateum://other?path=/")!) == nil)
        #expect(AppURL(URL(string: "https://open?path=/")!) == nil)
    }
}
