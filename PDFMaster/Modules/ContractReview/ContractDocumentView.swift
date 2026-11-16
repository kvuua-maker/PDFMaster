import PDFKit
import SwiftUI
import UIKit

/// The page the finding points at, zoomed to the paragraph and with the
/// anchors highlighted. This is the proof that a finding is not generic advice
/// but a specific clause of this document.
struct ContractDocumentView: View {
    let sourceURL: URL?
    let pageIndex: Int
    let anchors: [ReviewAnchor]
    let title: String
    let quote: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                HighlightPageView(image: image, highlight: normalisedHighlight)
                    .ignoresSafeArea(edges: .bottom)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "doc.questionmark").font(.largeTitle)
                    Text("Не вдалося відкрити сторінку документа")
                        .font(.footnote)
                }
                .foregroundStyle(MidnightGold.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(MidnightGold.gold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("«\(quote)»").font(.caption2).lineLimit(2)
                    .foregroundStyle(MidnightGold.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .midnightScreen()
        .navigationTitle("Сторінка \(pageIndex + 1)")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private var normalisedHighlight: CGRect? {
        guard let anchor = anchors.first else { return nil }
        if anchor.page != pageIndex { return nil }
        return CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h)
    }

    private func load() {
        guard let sourceURL else { failed = true; return }
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: sourceURL),
                  let page = document.page(at: pageIndex) else { failed = true; return }
            let media = page.bounds(for: .mediaBox)
            let width: CGFloat = 2200
            let target = CGSize(width: width, height: width * media.height / max(media.width, 1))
            image = page.thumbnail(of: target, for: .mediaBox)
        } else if let data = try? Data(contentsOf: sourceURL), let loaded = UIImage(data: data) {
            image = loaded
        } else {
            failed = true
        }
    }
}

/// Zoomable page with a rectangle over the anchored paragraph. Opens zoomed in
/// on the rectangle, so the user lands exactly on the clause.
private struct HighlightPageView: UIViewRepresentable {
    let image: UIImage
    let highlight: CGRect?

    func makeUIView(context: Context) -> HighlightingPage {
        HighlightingPage(image: image, highlight: highlight)
    }

    func updateUIView(_ view: HighlightingPage, context: Context) {}
}

@MainActor
final class HighlightingPage: UIView {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let marker = CAShapeLayer()
    private let zoomBridge = PageZoomBridge()
    private let highlight: CGRect?
    private var didFocus = false

    init(image: UIImage, highlight: CGRect?) {
        self.highlight = highlight
        super.init(frame: .zero)
        backgroundColor = MidnightGoldUIColor.canvas

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = zoomBridge
        zoomBridge.host = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)
        scrollView.contentSize = image.size

        marker.fillColor = UIColor.systemRed.withAlphaComponent(0.16).cgColor
        marker.strokeColor = UIColor.systemRed.cgColor
        marker.lineWidth = 2
        imageView.layer.addSublayer(marker)
        drawMarker()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 1, bounds.height > 1, imageView.image != nil else { return }
        let fit = min(bounds.width / imageView.image!.size.width,
                      bounds.height / imageView.image!.size.height)
        guard fit > 0 else { return }
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 5, fit + 0.5)
        if !didFocus {
            didFocus = true
            focusOnHighlight(fit: fit)
        } else if scrollView.zoomScale < fit {
            scrollView.zoomScale = fit
        }
    }

    private func focusOnHighlight(fit: CGFloat) {
        guard let highlight, highlight.width > 0 else {
            scrollView.zoomScale = fit
            return
        }
        let size = imageView.image!.size
        let rect = CGRect(x: highlight.minX * size.width,
                          y: highlight.minY * size.height,
                          width: max(highlight.width * size.width, 1),
                          height: max(highlight.height * size.height, 1))
        let target = min(max(fit * 2.4, fit), scrollView.maximumZoomScale)
        scrollView.zoomScale = target
        let offset = CGPoint(x: rect.midX * target - bounds.width / 2,
                             y: rect.midY * target - bounds.height / 2)
        scrollView.contentOffset = offset
        marker.lineWidth = 2 / max(target, 0.01)
    }

    private func drawMarker() {
        guard let highlight, let size = imageView.image?.size else { return }
        let rect = CGRect(x: highlight.minX * size.width,
                          y: highlight.minY * size.height,
                          width: max(highlight.width * size.width, 2),
                          height: max(highlight.height * size.height, 2))
        let padded = rect.insetBy(dx: -4, dy: -4)
        marker.path = UIBezierPath(roundedRect: padded, cornerRadius: 4).cgPath
    }

    func zoomingView() -> UIView { imageView }
}

private enum MidnightGoldUIColor {
    static let canvas = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
}

private final class PageZoomBridge: NSObject, UIScrollViewDelegate {
    weak var host: HighlightingPage?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard let host else { return nil }
        var view: UIView?
        MainActor.assumeIsolated { view = host.zoomingView() }
        return view
    }
}
