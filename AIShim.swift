// AIShim.swift — expose Apple Intelligence (FoundationModels) to Objective-C.
//
// FoundationModels is Swift-only, so we wrap LanguageModelSession in an @objc
// class. The on-device model runs asynchronously; a semaphore bridges it to the
// synchronous call an Obj-C CLI expects.
//
// Compiled with module name `wtkit`, which generates `wtkit-Swift.h` for the
// Obj-C side to import.

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@objc(AIWriter)
public final class AIWriter: NSObject {

    /// True when the on-device model is present and usable on this machine.
    @objc public static func isAvailable() -> Bool {
        return SystemLanguageModel.default.isAvailable
    }

    /// Run `text` through the model under a system-prompt `instruction`.
    /// `usePCC` selects Private Cloud Compute (32K context, off-device) instead of
    /// the on-device model (4K context). Returns the output, or a string beginning
    /// with "ERROR:"; the sentinel "ERROR_CONTEXT" means the input exceeded the
    /// model's context window (the caller can suggest --pcc).
    @objc public func run(instruction: String, text: String, usePCC: Bool) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let result = NSMutableString()
        Task.detached {
            do {
                let session: LanguageModelSession
                if usePCC, #available(macOS 27.0, *) {
                    session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                                   instructions: instruction)
                } else {
                    session = LanguageModelSession(instructions: instruction)
                }
                let response = try await session.respond(to: text)
                result.setString(response.content)
            } catch {
                let d = String(describing: error).lowercased()
                if d.contains("context") && (d.contains("exceed") || d.contains("size")) {
                    result.setString("ERROR_CONTEXT")
                } else {
                    result.setString("ERROR: \(error)")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result as String
    }
}
