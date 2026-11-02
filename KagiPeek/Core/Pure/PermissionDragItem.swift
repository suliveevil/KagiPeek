import Foundation
import UniformTypeIdentifiers

/// The drag payload the guide hands to System Settings: the app bundle, as something a
/// privacy list can resolve into an app.
///
/// The obvious spelling is `NSItemProvider(contentsOf: Bundle.main.bundleURL)`. It looks
/// right — it advertises `public.file-url`, `public.url` and `com.apple.application-bundle`
/// — and it is wrong for a bundle, because it treats the `.app` as a file to read:
///
///     [com.apple.application-bundle] -> nil
///     err: Cannot load representation of type com.apple.application-bundle
///          NSPOSIXErrorDomain 21 "Is a directory"
///
/// A drop target that asks for the bundle type then gets an error *after* the drop has
/// already been accepted — the password prompt appears, the user authenticates, and nothing
/// is added to the list. That is exactly the failure this file exists to prevent, so the two
/// representations are registered by hand: the file URL as data (what the file-url type
/// means) and the bundle as a URL handed over without reading it.
enum PermissionDragItem {
    /// Something a privacy list can add and enable in one drop.
    static func provider(forAppAt bundleURL: URL) -> NSItemProvider {
        let provider = NSItemProvider()

        // `public.file-url` is the URL's data representation, not the file's contents.
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in
            completion?(bundleURL.dataRepresentation as NSData, nil)
        }

        // The bundle type, handed over as the URL itself. Not `registerFileRepresentation`:
        // that coordinates the drop and hands the target a *copy* under TemporaryItems,
        // which a privacy list would then add as a different app.
        provider.registerItem(forTypeIdentifier: UTType.applicationBundle.identifier) { completion, _, _ in
            completion?(bundleURL as NSURL, nil)
        }

        return provider
    }
}
