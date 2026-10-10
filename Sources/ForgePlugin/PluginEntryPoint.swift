import AinkradAppKit
import Foundation
import ForgeFeature

/// The bundle's principal class (matches `NSPrincipalClass` in Info.plist).
@objc(ForgePluginEntryPoint)
final class ForgePluginEntryPoint: NSObject, AinkradPluginEntryPoint {
    static func app() -> any AinkradApp.Type { ForgeApp.self }
}
