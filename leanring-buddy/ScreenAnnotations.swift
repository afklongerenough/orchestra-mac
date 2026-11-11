//
//  ScreenAnnotations.swift
//  leanring-buddy
//
//  Drawing on the screen to explain things — circles, boxes, arrows and
//  short labels — like HeyClicky's screen drawing. The voice model adds
//  [DRAW: ...] tags; shapes appear on the overlay for a few seconds.
//
//    [DRAW: circle x,y,radius]
//    [DRAW: box x1,y1,x2,y2]
//    [DRAW: arrow x1,y1,x2,y2]
//    [DRAW: label x,y some text]
//  Coordinates are screenshot pixels (top-left origin) of screen 1 (the
//  cursor screen) unless the tag ends with :screenN.
//
//  Also: the small "notch" status pill at the top of the main screen that
//  shows when Live mode is on or jobs are running.
//

import AppKit
import SwiftUI

/// One shape, already converted to global AppKit coordinates.
struct ScreenAnnotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case circle(center: CGPoint, radius: CGFloat)
        case box(rect: CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case label(position: CGPoint, text: String)
    }

    let id = UUID()
    let shape: Shape
}

enum ScreenAnnotationParser {
    /// Turns [DRAW: ...] tag contents into shapes in global AppKit coordinates.
    @MainActor
    static func annotations(fromDrawCommands drawCommands: [String],
                            screenCaptures: [CompanionScreenCapture]) -> [ScreenAnnotation] {
        // A plain loop (not compactMap) so everything stays on the main actor.
        var parsedAnnotations: [ScreenAnnotation] = []
        for drawCommand in drawCommands {
            if let parsedAnnotation = annotation(fromDrawCommand: drawCommand, screenCaptures: screenCaptures) {
                parsedAnnotations.append(parsedAnnotation)
            }
        }
        return parsedAnnotations
    }

    @MainActor
    private static func annotation(fromDrawCommand drawCommand: String,
                                   screenCaptures: [CompanionScreenCapture]) -> ScreenAnnotation? {
            var commandText = drawCommand.trimmingCharacters(in: .whitespaces)
            var screenNumber: Int?
            if let screenRange = commandText.range(of: #":screen(\d+)\s*$"#, options: .regularExpression) {
                screenNumber = Int(commandText[screenRange].filter(\.isNumber))
                commandText.removeSubrange(screenRange)
            }
            guard let screenCapture = ScreenTakeoverSession.screenCapture(number: screenNumber, in: screenCaptures) else { return nil }

            let commandWords = commandText.split(separator: " ", maxSplits: 1).map(String.init)
            guard let shapeName = commandWords.first?.lowercased(), commandWords.count == 2 else { return nil }
            let argumentText = commandWords[1]

            func globalPoint(_ screenshotX: Double, _ screenshotY: Double) -> CGPoint {
                ScreenControl.appKitGlobalPoint(fromScreenshotPoint: CGPoint(x: screenshotX, y: screenshotY), in: screenCapture)
            }
            let pointsPerScreenshotPixel = CGFloat(screenCapture.displayWidthInPoints) / CGFloat(max(1, screenCapture.screenshotWidthInPixels))

            switch shapeName {
            case "circle":
                let numbers = leadingNumbers(in: argumentText, count: 3)
                guard numbers.count == 3 else { return nil }
                return ScreenAnnotation(shape: .circle(center: globalPoint(numbers[0], numbers[1]),
                                                       radius: CGFloat(numbers[2]) * pointsPerScreenshotPixel))
            case "box", "rect", "rectangle":
                let numbers = leadingNumbers(in: argumentText, count: 4)
                guard numbers.count == 4 else { return nil }
                let firstCorner = globalPoint(numbers[0], numbers[1])
                let secondCorner = globalPoint(numbers[2], numbers[3])
                return ScreenAnnotation(shape: .box(rect: CGRect(
                    x: min(firstCorner.x, secondCorner.x), y: min(firstCorner.y, secondCorner.y),
                    width: abs(secondCorner.x - firstCorner.x), height: abs(secondCorner.y - firstCorner.y))))
            case "arrow":
                let numbers = leadingNumbers(in: argumentText, count: 4)
                guard numbers.count == 4 else { return nil }
                return ScreenAnnotation(shape: .arrow(from: globalPoint(numbers[0], numbers[1]),
                                                      to: globalPoint(numbers[2], numbers[3])))
            case "label", "text":
                let numbers = leadingNumbers(in: argumentText, count: 2)
                guard numbers.count == 2,
                      let textStartRange = argumentText.range(of: #"^\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*"#, options: .regularExpression) else { return nil }
                let labelText = String(argumentText[textStartRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !labelText.isEmpty else { return nil }
                return ScreenAnnotation(shape: .label(position: globalPoint(numbers[0], numbers[1]), text: labelText))
            default:
                return nil
            }
    }

    /// First `count` numbers in "120, 340, 40" style text.
    private static func leadingNumbers(in text: String, count: Int) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(count)
        return matches.compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }
}

/// Draws the annotations that fall on one screen's overlay window.
struct ScreenAnnotationLayer: View {
    let screenFrame: CGRect
    let annotations: [ScreenAnnotation]

    private let annotationColor = Color(red: 1.0, green: 0.27, blue: 0.35)

    /// Global AppKit (bottom-left origin) → this overlay's SwiftUI space (top-left origin).
    private func localPoint(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.minX, y: screenFrame.maxY - globalPoint.y)
    }

    private func isOnThisScreen(_ annotation: ScreenAnnotation) -> Bool {
        switch annotation.shape {
        case .circle(let center, _): return screenFrame.contains(center)
        case .box(let rect): return screenFrame.contains(CGPoint(x: rect.midX, y: rect.midY))
        case .arrow(_, let to): return screenFrame.contains(to)
        case .label(let position, _): return screenFrame.contains(position)
        }
    }

    var body: some View {
        ZStack {
            ForEach(annotations.filter(isOnThisScreen)) { annotation in
                annotationView(annotation)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func annotationView(_ annotation: ScreenAnnotation) -> some View {
        switch annotation.shape {
        case .circle(let center, let radius):
            let localCenter = localPoint(center)
            Circle()
                .stroke(annotationColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .shadow(color: annotationColor.opacity(0.6), radius: 6)
                .position(localCenter)
                .transition(.scale.combined(with: .opacity))
        case .box(let rect):
            let topLeft = localPoint(CGPoint(x: rect.minX, y: rect.maxY))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(annotationColor, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                .frame(width: rect.width, height: rect.height)
                .shadow(color: annotationColor.opacity(0.6), radius: 6)
                .position(x: topLeft.x + rect.width / 2, y: topLeft.y + rect.height / 2)
                .transition(.opacity)
        case .arrow(let from, let to):
            ArrowShape(start: localPoint(from), end: localPoint(to))
                .stroke(annotationColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .shadow(color: annotationColor.opacity(0.6), radius: 6)
                .transition(.opacity)
        case .label(let position, let text):
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(annotationColor))
                .shadow(radius: 4)
                .position(localPoint(position))
                .transition(.opacity)
        }
    }
}

private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var arrowPath = Path()
        arrowPath.move(to: start)
        arrowPath.addLine(to: end)
        let shaftAngle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 18
        let headSpread: CGFloat = .pi / 7
        for headSide in [-1.0, 1.0] {
            let headAngle = shaftAngle + .pi + CGFloat(headSide) * headSpread
            arrowPath.move(to: end)
            arrowPath.addLine(to: CGPoint(x: end.x + headLength * cos(headAngle), y: end.y + headLength * sin(headAngle)))
        }
        return arrowPath
    }
}

/// Small capsule at the top-center of the main screen (under the notch on
/// notched MacBooks) showing Live mode and running jobs.
struct OrchestraStatusPill: View {
    let isLiveSessionActive: Bool
    let runningJobCount: Int
    /// Re-renders when the menu setting changes, so the pill always tells the truth.
    @AppStorage(ScreenSharingMode.defaultsKey) private var screenSharingModeRawValue = ScreenSharingMode.always.rawValue

    var body: some View {
        if isLiveSessionActive || runningJobCount > 0 {
            HStack(spacing: 8) {
                if isLiveSessionActive {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Live").font(.system(size: 11, weight: .semibold))
                    if screenSharingModeRawValue == ScreenSharingMode.always.rawValue {
                        // Live sends the screen every few seconds in this mode: keep that visible.
                        Image(systemName: "eye.fill").font(.system(size: 10))
                        Text("sharing screen").font(.system(size: 11, weight: .medium))
                    }
                }
                if runningJobCount > 0 {
                    if isLiveSessionActive {
                        Divider().frame(height: 10)
                    }
                    ProgressView().controlSize(.mini)
                    Text(runningJobCount == 1 ? "1 job working" : "\(runningJobCount) jobs working")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
