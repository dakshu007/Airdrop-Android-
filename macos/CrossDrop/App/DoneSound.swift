import AppKit
import CoreText

/// The soft "drop" played when files are verified (same sound as on Android).
enum DoneSound {
    private static let sound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "cd_done", withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.6
        return sound
    }()

    static func play() {
        guard let sound = sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

/// Registers the bundled Poppins faces (OFL) for this process so `Font.custom` finds them.
enum BundledFonts {
    static func register() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
