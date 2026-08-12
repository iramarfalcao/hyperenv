//
//  Feedback.swift
//  hyperenv
//
//  Sound for the four moments that change the machine.
//
//  Deliberately sparing. Applying a profile, reverting one, copying the reload
//  command and failing are the only events worth a sound — they are the ones
//  where the user's attention may be in a terminal rather than on this window,
//  and a sound is the only channel that reaches them there. Everything else
//  stays silent, because an app that chirps at every click gets muted, and then
//  the four that mattered are lost too.
//

import AppKit
import SwiftUI

@MainActor
enum Feedback {

    enum Cue {
        /// A profile is now live. New terminals will differ from old ones.
        case applied
        /// Back to the user's own environment.
        case reverted
        /// The reload command is on the pasteboard, ready to paste in a shell.
        case copied
        /// Something failed and the alert may be behind another window.
        case failed

        var soundName: String {
            switch self {
            case .applied: "Glass"
            case .reverted: "Bottle"
            case .copied: "Tink"
            case .failed: "Basso"
            }
        }
    }

    // MARK: Preference

    private static let key = "soundEffectsEnabled"

    /// On by default, and switchable from the Environment menu.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// macOS's own "play user interface sound effects" switch.
    ///
    /// Honoured even when this app's preference is on: someone who has turned
    /// interface sounds off system-wide has already answered this question, and
    /// should not have to answer it again per app.
    private static var systemAllowsInterfaceSounds: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    // MARK: Playing

    static func play(_ cue: Cue) {
        guard isEnabled, systemAllowsInterfaceSounds else { return }
        NSSound(named: cue.soundName)?.play()
    }
}
