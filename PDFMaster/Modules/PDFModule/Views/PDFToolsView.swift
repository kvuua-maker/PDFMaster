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

    private func openCamera(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            if await CameraAccess.request() {
                present()
            }
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
                Button(PDFL10n.t("Зробити фото")) { openCamera { model.showCamera = true } }
                Button(PDFL10n.t("Вибрати з галереї")) { model.showPhotoPicker = true }
                Button(PDFL10n.t("Сканувати документ")) { openCamera { model.showScanner = true } }
                Button(PDFL10n.t("Скасувати"), role: .cancel) {}
            }
            .photosPicker(isPresented: $model.showPhotoPicker, selection: $model.photoItems, maxSelectionCount: 20, matching: .images)
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
                AnnotationPlacementView(image: model.signatureBackground(), kind: model.placementKind) { rect in
                    model.placeAnnotation(rect)
                } onCancel: {
                    model.showPlacement = false
                }
            }
            .sheet(isPresented: $model.showViewer) {
                PDFPageViewer(url: model.results.first ?? URL(fileURLWithPath: "/"),
                              pageIndex: model.viewerPage)
            }
            .fullScreenCover(isPresented: $model.showScanner) {
                // VisionKit's scanner is the unstable part on recent iOS; the
                // system camera is plain, supported and never crashes.
                if CameraAccess.isCameraAvailable {
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
