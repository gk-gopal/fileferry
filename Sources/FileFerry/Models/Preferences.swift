import Foundation
import Observation
import TransportKit

/// The small amount of state FileFerry keeps between launches.
///
/// Deliberately narrow: pinned folders, where each pane was last looking, and
/// a handful of settings. Nothing records *what* was transferred, when, or to
/// where — this app keeps no transfer history by design.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let macPins = "macPins"
        static let phonePins = "phonePins"
        static let macLastPath = "macLastPath"
        static let phoneLastPath = "phoneLastPath"
        static let conflictPolicy = "conflictPolicy"
        static let concurrency = "concurrency"
        static let adbPath = "adbPath"
        static let showPreviewStrip = "showPreviewStrip"
        static let autoPreviewLimitMB = "autoPreviewLimitMB"
        static let restoreLastFolder = "restoreLastFolder"
    }

    var macPins: [String] {
        didSet { defaults.set(macPins, forKey: Key.macPins) }
    }
    var phonePins: [String] {
        didSet { defaults.set(phonePins, forKey: Key.phonePins) }
    }
    var macLastPath: String? {
        didSet { defaults.set(macLastPath, forKey: Key.macLastPath) }
    }
    var phoneLastPath: String? {
        didSet { defaults.set(phoneLastPath, forKey: Key.phoneLastPath) }
    }
    var conflictPolicyName: String {
        didSet { defaults.set(conflictPolicyName, forKey: Key.conflictPolicy) }
    }
    var concurrency: Int {
        didSet { defaults.set(concurrency, forKey: Key.concurrency) }
    }
    /// Empty means "search the usual locations".
    var adbPath: String {
        didSet { defaults.set(adbPath, forKey: Key.adbPath) }
    }
    var showPreviewStrip: Bool {
        didSet { defaults.set(showPreviewStrip, forKey: Key.showPreviewStrip) }
    }
    var autoPreviewLimitMB: Int {
        didSet { defaults.set(autoPreviewLimitMB, forKey: Key.autoPreviewLimitMB) }
    }
    var restoreLastFolder: Bool {
        didSet { defaults.set(restoreLastFolder, forKey: Key.restoreLastFolder) }
    }

    private init() {
        defaults.register(defaults: [
            Key.concurrency: 2,
            Key.conflictPolicy: "rename",
            Key.showPreviewStrip: true,
            Key.autoPreviewLimitMB: 50,
            Key.restoreLastFolder: true,
        ])
        macPins = defaults.stringArray(forKey: Key.macPins) ?? []
        phonePins = defaults.stringArray(forKey: Key.phonePins) ?? []
        macLastPath = defaults.string(forKey: Key.macLastPath)
        phoneLastPath = defaults.string(forKey: Key.phoneLastPath)
        conflictPolicyName = defaults.string(forKey: Key.conflictPolicy) ?? "rename"
        concurrency = defaults.integer(forKey: Key.concurrency)
        adbPath = defaults.string(forKey: Key.adbPath) ?? ""
        showPreviewStrip = defaults.bool(forKey: Key.showPreviewStrip)
        autoPreviewLimitMB = defaults.integer(forKey: Key.autoPreviewLimitMB)
        restoreLastFolder = defaults.bool(forKey: Key.restoreLastFolder)
    }

    var conflictPolicy: ConflictPolicy {
        switch conflictPolicyName {
        case "skip": .skip
        case "overwrite": .overwrite
        case "fail": .fail
        default: .rename
        }
    }

    var autoPreviewLimitBytes: Int64 {
        Int64(autoPreviewLimitMB) * 1024 * 1024
    }

    var resolvedADBPath: String? {
        adbPath.trimmingCharacters(in: .whitespaces).isEmpty ? nil : adbPath
    }

    func pins(isPhone: Bool) -> [String] {
        isPhone ? phonePins : macPins
    }

    func togglePin(_ path: String, isPhone: Bool) {
        if isPhone {
            if let index = phonePins.firstIndex(of: path) { phonePins.remove(at: index) }
            else { phonePins.append(path) }
        } else {
            if let index = macPins.firstIndex(of: path) { macPins.remove(at: index) }
            else { macPins.append(path) }
        }
    }

    func isPinned(_ path: String, isPhone: Bool) -> Bool {
        pins(isPhone: isPhone).contains(path)
    }
}
