import SwiftUI
import CoreGraphics

enum CropSelectionMode: String, CaseIterable, Identifiable {
    case area
    case trimEdges

    var id: String { rawValue }
    var title: String { self == .area ? "Select Area" : "Trim Edges" }
}

/// Text-aware crop canvas. Area mode draws/moves a rectangle; Trim Edges mode
/// exposes independent top/bottom/left/right handles so chrome can be shaved
/// off a screen recording without having to redraw the crop from scratch.
struct FrameCropCanvas: View {
    let image: CGImage
    @Binding var selection: NormalizedCrop?
    var mode: CropSelectionMode = .area

    @State private var dragOrigin: CGRect?

    private enum CropEdge: CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / CGFloat(max(image.width, 1)),
                geometry.size.height / CGFloat(max(image.height, 1))
            )
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)

            ZStack {
                ZStack(alignment: .topLeading) {
                    Image(platformImage: .from(cgImage: image))
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .accessibilityHidden(true)

                    if mode == .area {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(newSelectionGesture(in: size))
                    }

                    if let selection {
                        cropOverlay(selection: selection, size: size)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .background(Color.black.opacity(0.92))
        .accessibilityLabel(mode == .trimEdges
            ? "Image trim editor. Drag an edge inward to exclude it from text recognition."
            : "Text area selection. Drag on the image to select a rectangle.")
    }

    @ViewBuilder
    private func cropOverlay(selection: NormalizedCrop, size: CGSize) -> some View {
        let rect = displayRect(selection, size: size)

        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(.black.opacity(0.52), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        if mode == .trimEdges {
            cropGrid(in: rect)
        }

        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(.white, lineWidth: 2))
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .gesture(moveGesture(selection: selection, size: size))

        ForEach(0..<4, id: \.self) { corner in
            cornerHandle(corner, rect: rect, selection: selection, size: size)
        }

        if mode == .trimEdges {
            ForEach(CropEdge.allCases) { edge in
                edgeHandle(edge, rect: rect, selection: selection, size: size)
            }
        }
    }

    private func cropGrid(in rect: CGRect) -> some View {
        Path { path in
            for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                let x = rect.minX + rect.width * fraction
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.28), lineWidth: 0.75)
        .allowsHitTesting(false)
    }

    private func cornerHandle(_ corner: Int, rect: CGRect, selection: NormalizedCrop, size: CGSize) -> some View {
        let left = corner == 0 || corner == 2
        let top = corner < 2
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
            .gesture(cornerGesture(left: left, top: top, selection: selection, size: size))
            .accessibilityLabel(cornerAccessibilityLabel(corner))
            .accessibilityHidden(mode == .trimEdges)
    }

    private func edgeHandle(_ edge: CropEdge, rect: CGRect, selection: NormalizedCrop, size: CGSize) -> some View {
        let verticalEdge = edge == .left || edge == .right
        let x: CGFloat = edge == .left ? rect.minX : edge == .right ? rect.maxX : rect.midX
        let y: CGFloat = edge == .top ? rect.minY : edge == .bottom ? rect.maxY : rect.midY

        return Capsule()
            .fill(.white)
            .frame(width: verticalEdge ? 5 : 34, height: verticalEdge ? 34 : 5)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .gesture(edgeGesture(edge, selection: selection, size: size))
            .accessibilityLabel(edgeAccessibilityLabel(edge))
            .accessibilityValue(edgeAccessibilityValue(edge, selection: selection))
            .accessibilityAdjustableAction { direction in
                adjustEdge(edge, selection: selection, direction: direction)
            }
    }

    private func cornerAccessibilityLabel(_ corner: Int) -> String {
        switch corner {
        case 0: return "Top left crop corner"
        case 1: return "Top right crop corner"
        case 2: return "Bottom left crop corner"
        default: return "Bottom right crop corner"
        }
    }

    private func edgeAccessibilityLabel(_ edge: CropEdge) -> String {
        switch edge {
        case .top: return "Top trim edge"
        case .bottom: return "Bottom trim edge"
        case .left: return "Left trim edge"
        case .right: return "Right trim edge"
        }
    }

    private func edgeAccessibilityValue(_ edge: CropEdge, selection: NormalizedCrop) -> String {
        let trim: CGFloat
        switch edge {
        case .top: trim = selection.rect.minY
        case .bottom: trim = 1 - selection.rect.maxY
        case .left: trim = selection.rect.minX
        case .right: trim = 1 - selection.rect.maxX
        }
        return "\(Int((trim * 100).rounded())) percent trimmed"
    }

    private func adjustEdge(
        _ edge: CropEdge,
        selection: NormalizedCrop,
        direction: AccessibilityAdjustmentDirection
    ) {
        let delta: CGFloat
        switch direction {
        case .increment: delta = 0.02
        case .decrement: delta = -0.02
        @unknown default: return
        }

        var rect = selection.rect
        let minimumSize: CGFloat = 0.03
        switch edge {
        case .left:
            let newX = min(max(0, rect.minX + delta), rect.maxX - minimumSize)
            rect.size.width = rect.maxX - newX
            rect.origin.x = newX
        case .right:
            let newMaxX = max(min(1, rect.maxX - delta), rect.minX + minimumSize)
            rect.size.width = newMaxX - rect.minX
        case .top:
            let newY = min(max(0, rect.minY + delta), rect.maxY - minimumSize)
            rect.size.height = rect.maxY - newY
            rect.origin.y = newY
        case .bottom:
            let newMaxY = max(min(1, rect.maxY - delta), rect.minY + minimumSize)
            rect.size.height = newMaxY - rect.minY
        }
        self.selection = NormalizedCrop(rect: rect)
    }

    private func newSelectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let a = normalizedPoint(value.startLocation, in: size)
                let b = normalizedPoint(value.location, in: size)
                selection = NormalizedCrop(rect: CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y),
                    width: abs(a.x - b.x), height: abs(a.y - b.y)
                ))
            }
    }

    private func moveGesture(selection: NormalizedCrop, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = selection.rect }
                guard let start = dragOrigin, size.width > 0, size.height > 0 else { return }
                let x = min(max(0, start.minX + value.translation.width / size.width), 1 - start.width)
                let y = min(max(0, start.minY + value.translation.height / size.height), 1 - start.height)
                self.selection = NormalizedCrop(rect: CGRect(x: x, y: y, width: start.width, height: start.height))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func cornerGesture(left: Bool, top: Bool, selection: NormalizedCrop, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = selection.rect }
                guard let start = dragOrigin, size.width > 0, size.height > 0 else { return }
                let fixed = CGPoint(x: left ? start.maxX : start.minX, y: top ? start.maxY : start.minY)
                let moving = CGPoint(
                    x: min(1, max(0, (left ? start.minX : start.maxX) + value.translation.width / size.width)),
                    y: min(1, max(0, (top ? start.minY : start.maxY) + value.translation.height / size.height))
                )
                self.selection = normalizedCrop(fixed: fixed, moving: moving)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func edgeGesture(_ edge: CropEdge, selection: NormalizedCrop, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = selection.rect }
                guard var rect = dragOrigin, size.width > 0, size.height > 0 else { return }
                let minimumSize = 0.03
                switch edge {
                case .left:
                    let newX = min(max(0, rect.minX + value.translation.width / size.width), rect.maxX - minimumSize)
                    rect.size.width = rect.maxX - newX
                    rect.origin.x = newX
                case .right:
                    let newMaxX = max(min(1, rect.maxX + value.translation.width / size.width), rect.minX + minimumSize)
                    rect.size.width = newMaxX - rect.minX
                case .top:
                    let newY = min(max(0, rect.minY + value.translation.height / size.height), rect.maxY - minimumSize)
                    rect.size.height = rect.maxY - newY
                    rect.origin.y = newY
                case .bottom:
                    let newMaxY = max(min(1, rect.maxY + value.translation.height / size.height), rect.minY + minimumSize)
                    rect.size.height = newMaxY - rect.minY
                }
                self.selection = NormalizedCrop(rect: rect)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func normalizedCrop(fixed: CGPoint, moving: CGPoint) -> NormalizedCrop {
        NormalizedCrop(rect: CGRect(
            x: min(fixed.x, moving.x), y: min(fixed.y, moving.y),
            width: abs(fixed.x - moving.x), height: abs(fixed.y - moving.y)
        ))
    }

    private func displayRect(_ crop: NormalizedCrop, size: CGSize) -> CGRect {
        CGRect(
            x: crop.x * size.width, y: crop.y * size.height,
            width: crop.width * size.width, height: crop.height * size.height
        )
    }

    private func normalizedPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(1, max(0, point.x / size.width)),
            y: min(1, max(0, point.y / size.height))
        )
    }
}
