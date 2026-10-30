import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// PDF workspace shell. All state lives in PDFToolsModel and the sections are
/// separate views, keeping every expression small enough to type-check.
struct PDFToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = PDFToolsModel()

    var body: some View {
        NavigationStack {
            List {
                PDFCreateSection(model: model)
                PDFSearchSection(model: model)
                PDFConvertSection(model: model)
                PDFEditSection(model: model)
                PDFResultsSection(model: model)
            }
            .midnightScreen()
            .navigationTitle(PDFL10n.t("PDF-інструменти"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PDFL10n.t("Закрити")) { dismiss() }
                }
            }
            .modifier(PDFToolsBindings(model: model))
        }
    }

}

/// Pickers, sheets and alerts attached to the workspace.
private struct PDFToolsBindings: ViewModifier {
    @Bindable var model: PDFToolsModel

    func body(content: Content) -> some View {
        content
            .overlay { if model.isBusy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog("PDF з фото", isPresented: $model.showPhotoChoice, titleVisibility: .visible) {
                Button(PDFL10n.t("Зробити фото")) { openCameraWhenPermitted { model.showCamera = true } }
                Button(PDFL10n.t("Вибрати з галереї")) { model.showPhotoPicker = true }
                Button(PDFL10n.t("Сканувати документ")) { openCameraWhenPermitted { model.showScanner = true } }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .fullScreenCover(isPresented: $model.showPhotoPicker) {
                SystemPhotoPicker { images in
                    RuntimeDiagnostics.shared.log("photos", "picked \(images.count) images")
                    model.add(images: images)
                }
            }
            .fullScreenCover(isPresented: $model.showCamera) {
                if CameraAccess.isCameraAvailable {
                    CameraPhotoPicker { image in model.add(image: image) }
                } else {
                    UnsupportedCameraView()
                }
            }
            .photosPicker(isPresented: $model.showLogoPicker, selection: $model.logoItem, matching: .images)
            .onChange(of: model.logoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        model.applyLogoWatermark(image)
                    }
                    model.logoItem = nil
                }
            }
            .fullScreenCover(isPresented: $model.showCrop) {
                CropView(image: model.signatureBackground(), onlyFirstPage: $model.cropOnlyFirstPage) { rect in
                    model.applyCrop(rect)
                } onCancel: {
                    model.showCrop = false
                }
            }
            .fullScreenCover(isPresented: $model.showPlacement) {
                AnnotationPlacementView(image: model.placementImage, kind: model.placementKind) { rect in
                    model.placeAnnotation(rect)
                } onCancel: {
                    model.cancelPlacement()
                }
            }
            .sheet(isPresented: $model.showViewer) {
                PDFPageViewer(url: model.results.first ?? URL(fileURLWithPath: "/"),
                              pageIndex: model.viewerPage)
            }
            .fullScreenCover(isPresented: $model.showScanner) {
                // VisionKit gives edge detection and perspective correction; the
                // plain camera stays as the fallback when it is unsupported.
                if CameraAccess.canScanDocuments {
                    DocumentScannerView { pages in
                        RuntimeDiagnostics.shared.log("scanner", "VisionKit returned \(pages.count) pages")
                        model.scanPages(pages)
                    }
                } else if CameraAccess.isCameraAvailable {
                    CameraPhotoPicker { image in model.scanPages([image]) }
                } else {
                    UnsupportedCameraView()
                }
            }
            .onChange(of: model.photoItems) { _, items in
                if !items.isEmpty { Task { await model.buildFromPhotos() } }
            }
            .fileImporter(isPresented: $model.showPDFImport, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { outcome in
                if case let .success(urls) = outcome { model.mergeFiles(urls.map(FileImport.copy)) }
            }
            .sheet(isPresented: $model.showOffice) { OfficeConvertView() }
            .sheet(isPresented: $model.showFileActions) { PDFFileActionsView() }
            .sheet(isPresented: $model.showPaywall) { ProView() }
            .confirmationDialog("Підпис", isPresented: $model.showSignatureHome, titleVisibility: .visible) {
                if model.savedSignature != nil {
                    Button(PDFL10n.t("Використати збережений підпис")) { model.useSavedSignature() }
                }
                Button(PDFL10n.t("Намалювати новий")) { model.showSignature = true }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .fullScreenCover(isPresented: $model.showSignature) {
                SignaturePadView(background: model.signatureBackground()) { image, rect in
                    model.signatureImage = image
                    model.saveSignatureImage(image)
                    model.applySignature(image: image, rect: rect)
                } onCancel: {
                    model.showSignature = false
                }
            }
            .sheet(item: $model.previewItem) { item in PDFPreviewSheet(url: item.url) }
            .modifier(PDFToolsAlerts(model: model))
    }
}

private struct PDFToolsAlerts: ViewModifier {
    @Bindable var model: PDFToolsModel

    func body(content: Content) -> some View {
        content
            .alert(PDFL10n.t("Водяний знак"), isPresented: $model.showWatermark) {
                TextField("Текст", text: $model.watermarkText)
                Button(PDFL10n.t("Застосувати")) { model.applyWatermark() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Зняти пароль"), isPresented: $model.showRemovePassword) {
                TextField("Поточний пароль", text: $model.passwordText)
                Button(PDFL10n.t("Зняти")) { model.removePassword() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Пароль"), isPresented: $model.showPassword) {
                TextField("Пароль", text: $model.passwordText)
                Button(PDFL10n.t("Захистити")) { model.applyPassword() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Текст на сторінку"), isPresented: $model.showText) {
                TextField("Текст", text: $model.textToInsert)
                Button(PDFL10n.t("Додати")) { model.applyText() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Витягти сторінки"), isPresented: $model.showSplit) {
                TextField("1-2", text: $model.splitRange)
                Button(PDFL10n.t("Витягти")) { model.splitPages() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Видалити сторінки"), isPresented: $model.showDeletePage) {
                TextField("2-4", text: $model.deleteRange)
                Button(PDFL10n.t("Видалити"), role: .destructive) { model.deleteRangePages() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Верхній колонтитул"), isPresented: $model.showHeader) {
                TextField("Текст", text: $model.headerText)
                Button(PDFL10n.t("Додати")) { model.applyHeader() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Перемістити сторінку"), isPresented: $model.showMovePage) {
                TextField("З", text: $model.moveFrom)
                TextField("На", text: $model.moveTo)
                Button(PDFL10n.t("Перемістити")) { model.movePage() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Дублювати сторінку"), isPresented: $model.showDuplicatePage) {
                TextField("1", text: $model.duplicateIndex)
                Button(PDFL10n.t("Дублювати")) { model.duplicateChosenPage() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Номер сторінки"), isPresented: $model.showBlank) {
                TextField("1", text: $model.blankIndex)
                Button(PDFL10n.t("Вставити")) { model.insertBlankPage() }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .alert(PDFL10n.t("Помилка"), isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button(PDFL10n.t("OK"), role: .cancel) { model.alertMessage = nil }
            } message: {
                Text(model.alertMessage ?? "")
            }
    }

}

/// Ask for camera permission, then present. Shared by the workspace and its
/// modifier so protection lives in one place.
@MainActor
private enum CameraPresentation {
    static var inFlight = false
}

@MainActor
func openCameraWhenPermitted(_ present: @escaping @MainActor () -> Void) {
    guard !CameraPresentation.inFlight else {
        RuntimeDiagnostics.shared.log("camera", "ignored duplicate request")
        return
    }
    CameraPresentation.inFlight = true
    Task { @MainActor in
        defer { CameraPresentation.inFlight = false }
        let available = CameraAccess.isCameraAvailable
        RuntimeDiagnostics.shared.log("camera", "requested, available=\(available)")
        if await CameraAccess.request() {
            RuntimeDiagnostics.shared.log("camera", "presenting picker")
            // One runloop turn avoids presenting on top of the dismissal
            // animation, which is a known crash source.
            try? await Task.sleep(for: .milliseconds(350))
            present()
        } else {
            RuntimeDiagnostics.shared.log("camera", "permission denied or unavailable")
        }
    }
}
