import Foundation

/// Localisation for the PDF module. Ukrainian is the source language; English is
/// served from the table below so the module is not a mix of languages.
enum PDFL10n {
    private static var isEnglish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") == true
    }

    static func t(_ ukrainian: String) -> String {
        guard isEnglish else { return ukrainian }
        return english[ukrainian] ?? ukrainian
    }

    private static let english: [String: String] = [
        // Sections
        "Створити": "Create",
        "Пошук": "Search",
        "Конвертувати": "Convert",
        "Конвертувати та оформити": "Convert & style",
        "Редагувати": "Edit",
        "Результати": "Results",
        "Спочатку створіть або виберіть PDF": "Create or pick a PDF first",
        "Тут з’являться створені файли": "Created files appear here",
        // Create
        "PDF з фото": "PDF from photos",
        "Порожній PDF": "Blank PDF",
        "Об’єднати PDF-файли": "Merge PDFs",
        "Word / Excel → PDF": "Word / Excel → PDF",
        "Інструменти для файлу": "File tools",
        "Підпис": "Signature",
        "Зробити фото": "Take photo",
        "Вибрати з галереї": "Choose from library",
        "Сканувати документ": "Scan document",
        "Скасувати": "Cancel",
        // Convert
        "PDF → Текст": "PDF → Text",
        "PDF → PNG": "PDF → PNG",
        "OCR: розпізнати текст": "OCR: recognise text",
        "Зробити PDF з пошуком (OCR-шар)": "Make PDF searchable (OCR layer)",
        "Обрізати поля…": "Crop margins…",
        "Розмір A4": "A4 size",
        "Розмір Letter": "Letter size",
        "Колонтитули (номер + дата)": "Page numbers + date",
        "Верхній колонтитул…": "Header…",
        "Водяний знак-логотип…": "Logo watermark…",
        "Пошук по тексту": "Search text",
        "Знайти": "Find",
        "Пошук у документі": "Search in document",
        "Перейти до знайденого": "Go to match",
        "Розпізнати текст для пошуку": "Recognise text for search",
        "Текст розпізнано": "Text recognised",
        "Текст успішно розпізнано! Збережіть файл і скористайтеся пошуком у будь-якому читачі PDF": "Text recognised successfully! Save the file and search it in any PDF reader.",
        // Edit
        "Повернути на 90°": "Rotate 90°",
        "Додати текст": "Add text",
        "Водяний знак": "Watermark",
        "Захистити паролем": "Protect with password",
        "Зняти пароль": "Remove password",
        "Стиснути": "Compress",
        "Вставити порожню сторінку": "Insert blank page",
        "Витягнути зображення": "Extract images",
        "Розділити: витягти сторінки": "Split: extract pages",
        "Видалити сторінки…": "Delete pages…",
        "Дублювати сторінку…": "Duplicate page…",
        "Перемістити сторінку…": "Move page…",
        "Анотація": "Annotation",
        "Маркер": "Highlighter",
        "Підкреслення": "Underline",
        "Закреслення": "Strike out",
        "Прямокутник": "Rectangle",
        "Коло": "Ellipse",
        "Коментар": "Comment",
        // Results
        "Скасувати останню дію": "Undo",
        "Повторити дію": "Redo",
        "Перегляд": "Preview",
        "Друк": "Print",
        "Видалити зі списку": "Remove from list",
        "Зберегти у Файли": "Save to Files",
        // Dialogs
        "Водяний знак": "Watermark",
        "Пароль": "Password",
        "Текст на сторінку": "Text on page",
        "Номер сторінки": "Page number",
        "Витягти сторінки": "Extract pages",
        "Видалити сторінки": "Delete pages",
        "Дублювати сторінку": "Duplicate page",
        "Перемістити сторінку": "Move page",
        "Верхній колонтитул": "Header",
        "Зняти пароль": "Remove password",
        "Помилка": "Error",
        "Текст": "Text",
        "Додати": "Add",
        "Вставити": "Insert",
        "Застосувати": "Apply",
        "Готово": "Done",
        "Закрити": "Close",
        "Видалити": "Delete",
        "Дублювати": "Duplicate",
        "Перемістити": "Move",
        "Знайти": "Find",
        "Пошук у документі": "Search in document",
        "Перейти до знайденого": "Go to match",
        "Розпізнати текст для пошуку": "Recognise text for search",
        "Текст розпізнано": "Text recognised",
        "Текст успішно розпізнано! Збережіть файл і скористайтеся пошуком у будь-якому читачі PDF": "Text recognised successfully! Save the file and search it in any PDF reader.",
        "OK": "OK",
        // File tools screen
        "Вибрати PDF": "Choose PDF",
        "Інструменти для файлу": "File tools",
        "Перемістити анотації пальцем": "Move annotations by finger",
        "Не вдалося": "Failed",
        // Crop / annotation screens
        "Обрізати": "Crop",
        "Всі сторінки": "All pages",
        "Лише перша": "First page only",
        "Область": "Scope",
        "Використати збережений підпис": "Use saved signature",
        "Намалювати новий": "Draw a new one",
        "Намалюйте підпис поверх документа": "Draw your signature over the document",
        "Переміщення анотацій": "Move annotations",
        "Зберегти": "Save",
        "Сторінка": "Page"
    ]
}
