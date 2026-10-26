import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// State and operations for the PDF workspace. Keeping them out of the view
/// keeps each SwiftUI body small enough for the type checker.
@MainActor
@Observable
final class PDFToolsModel {
    var results: [URL] = []
    var importedPDFs: [URL] = []
    var photoItems: [PhotosPickerItem] = []
    var isBusy = false
    var statusLine: String?
    var signatureImage: UIImage?
    var annotationKind: PDFAnnotationKind = .highlight
    var watermarkText = ""
    var passwordText = ""
    var textToInsert = ""
    var officePDF: URL?
    var alertMessage: String?
    var _blankIndex = "1"
    var showPhotoChoice = false
    var showCamera = false
    var showPhotoPicker = false
    var showPDFImport = false
    var showOffice = false
    var showFileActions = false
    var showSignature = false
    var showSignatureHome = false
    var showWatermark = false
    var showPassword = false
    var showText = false
    var showBlank = false
    var showSplit = false
    var showDeletePage = false
    var splitRange = "1-2"
    var deletePageIndex = "1"
    var showRemovePassword = false
    var showScanner = false
    var searchQuery = ""
    var searchResult: String?
    var undoStack: [[URL]] = []
    var redoStack: [[URL]] = []
    var showCrop = false
    var showPlacement = false
    var placementKind: PDFAnnotationKind = .highlight
    var showViewer = false
    var viewerPage = 0
    var deleteRange = "2-4"
    var showDuplicatePage = false
    var duplicateIndex = "1"
    var searchMatches: [Int] = []
    var searchCursor = 0
    var ocrPages: [Int: String] = [:]
    var ocrSourceURL: URL?
    var showHeader = false
    var showOCRDone = false
    var headerText = ""
    var showLogoPicker = false
    var logoItem: PhotosPickerItem?
    var showMovePage = false
    var moveFrom = "1"
    var moveTo = "2"
    var cropOnlyFirstPage = false
    var shareURL: URL?
    var previewItem: PreviewTarget?

    func run(_ operation: @escaping () async throws -> URL?) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if let url = try await operation() {
                    undoStack.append(results)
                    redoStack.removeAll()
                    results.insert(url, at: 0)
                }
            } catch {
                statusLine = "Помилка: \(error)"
            }
        }
    }

    func buildFromPhotos() async {
        guard !photoItems.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var images: [UIImage] = []
        for item in photoItems {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoItems = []
        guard !images.isEmpty else { statusLine = "Не вдалося прочитати фото"; return }
        do {
            let url = try await PDFToolsEngine.shared.makePDF(from: images)
            results.insert(url, at: 0)
            statusLine = "PDF створено: \(images.count) сторінок"
        } catch {
            statusLine = "Помилка: \(error)"
        }
    }

    func convertOffice(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let pdf = try await OfficeConversionService.shared.convert(url)
            results.insert(pdf, at: 0)
            statusLine = "Word/Excel → PDF готово"
        } catch {
            statusLine = "Конвертація не вдалася: \(error)"
        }
    }

    func printPDF(_ url: URL) {
        guard UIPrintInteractionController.isPrintingAvailable else {
            statusLine = "Друк недоступний на цьому пристрої"
            return
        }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = url.lastPathComponent
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true)
    }

    func undo() {
        guard results.count > 1 else { return }
        results.removeFirst()
    }
}
