import UIKit

/// Small floating panel shown above an active selection:
/// `[↑] [↓] [✓ Apply] [✕ Clear]`.
///
/// Moving the selection up or down a row is pure `PageTextMap` arithmetic, so
/// the buttons respond immediately even when the page is zoomed in.
@MainActor
final class SelectionActionBar: UIView {
    static let barSize = CGSize(width: 162, height: 44)

    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onApply: (() -> Void)?
    var onClear: (() -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let upButton = UIButton(type: .system)
    private let downButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.barSize))
        isHidden = true

        blur.frame = bounds
        blur.layer.cornerRadius = 12
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.layer.borderWidth = 0.5
        blur.layer.borderColor = UIColor.separator.cgColor
        addSubview(blur)

        let buttons = [upButton, downButton, applyButton, clearButton]
        let symbols = ["chevron.up", "chevron.down", "checkmark", "xmark"]
        let labels = ["Рядок вище", "Рядок нижче", "Застосувати", "Прибрати виділення"]
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 6 + CGFloat(index) * 38, y: 4, width: 36, height: 36)
            button.setImage(UIImage(systemName: symbols[index],
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
                            for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = labels[index]
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            addSubview(button)
        }

        applyButton.tintColor = .systemBlue
        clearButton.tintColor = .secondaryLabel
        applyButton.accessibilityIdentifier = "annotation.apply"
        clearButton.accessibilityIdentifier = "annotation.clear"
        upButton.accessibilityIdentifier = "annotation.rowUp"
        downButton.accessibilityIdentifier = "annotation.rowDown"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(canMoveUp: Bool, canMoveDown: Bool) {
        upButton.isEnabled = canMoveUp
        downButton.isEnabled = canMoveDown
        upButton.alpha = canMoveUp ? 1 : 0.3
        downButton.alpha = canMoveDown ? 1 : 0.3
    }

    @objc private func tapped(_ sender: UIButton) {
        switch sender {
        case upButton: onMoveUp?()
        case downButton: onMoveDown?()
        case applyButton: onApply?()
        case clearButton: onClear?()
        default: break
        }
    }
}
