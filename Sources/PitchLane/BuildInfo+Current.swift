#if canImport(SwiftUI)
import Foundation
import PitchLaneCore

extension BuildInfo {
    /// Version/build of the running app, from its Info.plist.
    static var current: BuildInfo { BuildInfo(infoDictionary: Bundle.main.infoDictionary) }
}
#endif
