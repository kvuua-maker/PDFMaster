import UIKit

/// Round grab handle for a selection edge.
///
/// The visible dot is deliberately small; the view itself is 44×44 points so
/// the touch target meets the Human Interface Guideline minimum.
@MainActor
final class SelectionHandleView: UIView {
    static let touchSize: CGFloat = 44

    private let dot = UIView()
    private let ring = UIView()

    init(isStart: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.touchSize, height: Self.touchSize))
        backgroundColor = .clear
        isOpaque = false
        // Handles are only meaningful once a selection exists.
        isHidden = true

        let diameter: CGFloat = 18
        ring.frame = CGRect(x: (Self.touchSize - diameter) / 2,
                            y: (Self.touchSize - diameter) / 2,
                            width: diameter, height: diameter)
        ring.layer.cornerRadius = diameter / 2
        ring.backgroundColor = .white
        ring.layer.shadowColor = UIColor.black.cgColor
        ring.layer.shadowOpacity = 0.25
        ring.layer.shadowRadius = 3
        ring.layer.shadowOffset = CGSize(width: 0, height: 1)
        ring.isUserInteractionEnabled = false
        addSubview(ring)

        let inner: CGFloat = 10
        dot.frame = CGRect(x: (Self.touchSize - inner) / 2,
                           y: (Self.touchSize - inner) / 2,
                           width: inner, height: inner)
        dot.layer.cornerRadius = inner / 2
        dot.isUserInteractionEnabled = false
        addSubview(dot)

        accessibilityLabel = isStart ? "Початок виділення" : "Кінець виділення"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: UIColor) {
        dot.backgroundColor = color
    }
}
