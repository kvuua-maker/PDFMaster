import AVFoundation
import VisionKit
import UIKit

/// Camera availability and permission, checked before any picker is presented so
/// the app shows a message instead of crashing.
@MainActor
enum CameraAccess {
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static var canScanDocuments: Bool {
        isCameraAvailable && VNDocumentCameraSupport.isSupported
    }

    /// Async because AVCaptureDevice's callback cannot be forwarded across
    /// actors without a data-race warning.
    static func request() async -> Bool {
        guard isCameraAvailable else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

/// Tiny shim so the VisionKit check stays testable and out of the view.
@MainActor
enum VNDocumentCameraSupport {
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }
}
