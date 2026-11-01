import Foundation
import PaperVeilExtraction
import Testing

extension Trait where Self == ConditionTrait {
    /// OCR tests always run locally. Only on CI runners where Vision cannot run at all
    /// (virtualised Macs without Neural Engine) they are skipped – reported as skipped,
    /// documented in README/acceptance as "OCR nicht in CI geprüft, lokal verifiziert".
    static var requiresOCR: Self {
        .enabled("Vision-OCR verfügbar (auf CI-Runnern ohne OCR übersprungen)") {
            ProcessInfo.processInfo.environment["CI"] != "true" ? true : await OCRCompute.isAvailable()
        }
    }
}
