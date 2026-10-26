import SwiftUI

struct PDFCreateSection: View {
    let model: PDFToolsModel

    var body: some View {
        Section(PDFL10n.t("Створити")) {
            Button(PDFL10n.t("PDF з фото")) { model.showPhotoChoice = true }
            Button(PDFL10n.t("Порожній PDF")) { model.runBlank() }
            Button(PDFL10n.t("Об’єднати PDF-файли")) { model.showPDFImport = true }
            Button(PDFL10n.t("Word / Excel → PDF")) { model.showOffice = true }
            Button(PDFL10n.t("Інструменти для файлу")) { model.showFileActions = true }
            Button(PDFL10n.t("Підпис")) { model.showSignatureHome = true }
        }
    }
}

struct PDFSearchSection: View {
    @Bindable var model: PDFToolsModel

    var body: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(PDFL10n.t("Пошук по тексту"), text: $model.searchQuery)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { model.findPages() }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.searchResult = nil
                        model.searchMatches = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(PDFL10n.t("Знайти")) { model.findPages() }
                .disabled(model.results.isEmpty)
            if let result = model.searchResult {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            }
            if !model.searchMatches.isEmpty {
                Button(PDFL10n.t("Перейти до знайденого")) { model.nextSearchMatch() }
            }
        } header: {
            Label(PDFL10n.t("Пошук у документі"), systemImage: "doc.text.magnifyingglass")
        }
    }
}

struct PDFConvertSection: View {
    @Bindable var model: PDFToolsModel

    var body: some View {
        Section(PDFL10n.t("Конвертувати та оформити")) {
            if model.results.isEmpty {
                Text(PDFL10n.t("Спочатку створіть або виберіть PDF"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(PDFL10n.t("PDF → Текст")) { model.exportText() }
                Button(PDFL10n.t("PDF → PNG")) { model.exportPNG() }
                Button(PDFL10n.t("Розпізнати текст для пошуку")) { model.makeSearchable() }
                Button(PDFL10n.t("Обрізати поля…")) { model.showCrop = true }
                Button(PDFL10n.t("Розмір A4")) { model.resizeA4() }
                Button(PDFL10n.t("Розмір Letter")) { model.resizeLetter() }
                Button(PDFL10n.t("Колонтитули (номер + дата)")) { model.addFooters() }
                Button(PDFL10n.t("Верхній колонтитул…")) { model.headerText = ""; model.showHeader = true }
                Button(PDFL10n.t("Водяний знак-логотип…")) { model.showLogoPicker = true }
            }
        }
    }
}

struct PDFEditSection: View {
    let model: PDFToolsModel

    var body: some View {
        Section(PDFL10n.t("Редагувати")) {
            if model.results.isEmpty {
                Text(PDFL10n.t("Спочатку створіть або виберіть PDF"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let current = model.results.first {
                Button(PDFL10n.t("Повернути на 90°")) { model.rotate(current) }
                Button(PDFL10n.t("Додати текст")) { model.showText = true }
                Button(PDFL10n.t("Водяний знак")) { model.showWatermark = true }
                Button(PDFL10n.t("Захистити паролем")) { model.showPassword = true }
                Button(PDFL10n.t("Зняти пароль")) { model.passwordText = ""; model.showRemovePassword = true }
                Button(PDFL10n.t("Стиснути")) { model.compress(current) }
                Button(PDFL10n.t("Вставити порожню сторінку")) { model.showBlank = true }
                Button(PDFL10n.t("Витягнути зображення")) { model.extractImages() }
                Button(PDFL10n.t("Розділити: витягти сторінки")) { model.showSplit = true }
                Button(PDFL10n.t("Видалити сторінки…")) { model.deleteRange = "2-4"; model.showDeletePage = true }
                Button(PDFL10n.t("Дублювати сторінку…")) { model.duplicateIndex = "1"; model.showDuplicatePage = true }
                Button(PDFL10n.t("Перемістити сторінку…")) { model.moveFrom = "1"; model.moveTo = "2"; model.showMovePage = true }
                Menu("Анотація") {
                    Button(PDFL10n.t("Маркер")) { model.startPlacement(.highlight) }
                    Button(PDFL10n.t("Підкреслення")) { model.startPlacement(.underline) }
                    Button(PDFL10n.t("Закреслення")) { model.startPlacement(.strikeOut) }
                    Button(PDFL10n.t("Прямокутник")) { model.startPlacement(.square) }
                    Button(PDFL10n.t("Коло")) { model.startPlacement(.circle) }
                    Button(PDFL10n.t("Коментар")) { model.startPlacement(.comment) }
                }
            }
        }
    }
}

struct PDFResultsSection: View {
    @Bindable var model: PDFToolsModel

    var body: some View {
        Section(PDFL10n.t("Результати")) {
            if model.results.isEmpty {
                Text(PDFL10n.t("Тут з’являться створені файли")).font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.results, id: \.self) { url in
                    PDFResultRow(model: model, url: url)
                }
            }
            if model.results.count > 1 {
                Button(PDFL10n.t("Скасувати останню дію")) { model.undo() }
            }
            if model.canRedo {
                Button(PDFL10n.t("Повторити дію")) { model.redo() }
            }
            if let status = model.statusLine {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PDFResultRow: View {
    @Bindable var model: PDFToolsModel
    let url: URL

    var body: some View {
        HStack {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            SaveToFilesButton(url: url)
                .buttonStyle(.borderless)
            Menu {
                Button(PDFL10n.t("Перегляд")) { model.previewItem = PreviewTarget(url: url) }
                Button(PDFL10n.t("Друк")) { model.printPDF(url) }
                Button(PDFL10n.t("Видалити зі списку")) { model.results.removeAll { $0 == url } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
