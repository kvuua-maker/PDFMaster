import AVFoundation
import VisionKit
import UIKit

/// Camera availability and permission, checked before any picker is presented so
/// the app shows a message instead of crashing.
enum CameraAccess {
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static var canScanDocuments: Bool {
        isCameraAvailable && VNDocumentCameraSupport.isSupported
    }

    @MainActor
    static func request(completion: @escaping (Bool) -> Void) {
        guard isCameraAvailable else { completion(false); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
}

/// Tiny shim so the VisionKit check stays testable and out of the view.
enum VNDocumentCameraSupport {
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }
}
