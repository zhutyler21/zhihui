import SwiftUI

/// Original decorative artwork. No native controls or business content enter the shader layer.
struct WelcomeGlass: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var paused = false
    @State private var clockWasRunning = false
    @State private var accumulatedTime = 0.0
    @State private var clockStarted = Date()
    @State private var vertical = WelcomeGlassSpring(from: 0, to: 1, velocity: 0, started: 0)
    @State private var horizontal = WelcomeGlassSpring(from: 0, to: 0, velocity: 0, started: 0)
    @State private var dragOrigin: Double?
    @State private var dragProgress: Double?
    @State private var dragSideOrigin = 0.0
    @State private var dragSide = 0.0
    private let hasShader = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil

    private var staticPresentation: Bool { reduceMotion || reduceTransparency || !hasShader }
    private var clockRunning: Bool { !paused && !staticPresentation && scenePhase == .active }

    var body: some View {
        VStack(spacing: 18) {
            GeometryReader { geometry in
                // Only this artwork subtree ticks. Text and native controls outside it stay still.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !clockRunning)) { timeline in
                    let time = logicalTime(at: timeline.date)
                    let progress = staticPresentation ? 1 : dragProgress ?? vertical.sample(at: time).value
                    let side = staticPresentation ? 0 : dragOrigin != nil ? dragSide : horizontal.sample(at: time).value
                    let lens = WelcomeGlassGeometry(size: geometry.size, progress: progress, side: side)
                    WelcomeGlassArtwork(size: geometry.size, time: staticPresentation ? 0 : time,
                                        lens: lens, shaderEnabled: !staticPresentation,
                                        force: dragOrigin == nil ? 0.16 : 0.9, night: colorScheme == .dark)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(size: geometry.size), including: clockRunning ? .all : .none)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 500)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Design.line.opacity(0.6), lineWidth: 1) }

            HStack(spacing: 12) {
                Text(staticPresentation ? "静态展示 · 可直接开始设置" : "拖动玻璃球，看看讨论如何汇集")
                    .font(Design.Typography.caption).foregroundStyle(Design.muted)
                Spacer(minLength: 8)
                if !staticPresentation {
                    Button { paused.toggle() } label: {
                        Label(paused ? "继续动效" : "暂停动效", systemImage: paused ? "play.circle" : "pause.circle")
                    }.buttonStyle(.borderless).font(Design.Typography.caption)
                        .help("只影响欢迎页装饰，随时可以开始设置")
                    Button { replay() } label: { Label("重播", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).font(Design.Typography.caption)
                        .disabled(paused).help("重播玻璃穹顶收拢效果")
                }
            }
        }
        .onAppear {
            clockStarted = Date(); clockWasRunning = clockRunning
            if staticPresentation { vertical = WelcomeGlassSpring(from: 1, to: 1, velocity: 0, started: accumulatedTime) }
        }
        .onChange(of: clockRunning) { _, running in updateClock(running) }
        .onChange(of: staticPresentation) { _, staticMode in
            if staticMode {
                let time = logicalTime(at: Date())
                vertical = WelcomeGlassSpring(from: 1, to: 1, velocity: 0, started: time)
                horizontal = WelcomeGlassSpring(from: 0, to: 0, velocity: 0, started: time)
            }
            dragOrigin = nil; dragProgress = nil
        }
    }

    private func logicalTime(at date: Date) -> Double {
        accumulatedTime + (clockWasRunning ? max(0, date.timeIntervalSince(clockStarted)) : 0)
    }
    private func updateClock(_ running: Bool) {
        let now = Date()
        if clockWasRunning { accumulatedTime += max(0, now.timeIntervalSince(clockStarted)) }
        clockStarted = now; clockWasRunning = running
        if !running, let progress = dragProgress {
            vertical = WelcomeGlassSpring(from: progress, to: progress, velocity: 0, started: accumulatedTime)
            horizontal = WelcomeGlassSpring(from: dragSide, to: dragSide, velocity: 0, started: accumulatedTime)
            dragOrigin = nil; dragProgress = nil
        }
    }
    private func replay() {
        let time = logicalTime(at: Date())
        dragOrigin = nil; dragProgress = nil
        vertical = WelcomeGlassSpring(from: 0, to: 1, velocity: 0, started: time)
        horizontal = WelcomeGlassSpring(from: 0, to: 0, velocity: 0, started: time)
    }
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let time = logicalTime(at: Date())
                if dragOrigin == nil {
                    let current = vertical.sample(at: time).value
                    let currentSide = horizontal.sample(at: time).value
                    let lens = WelcomeGlassGeometry(size: size, progress: current, side: currentSide)
                    guard hypot(value.startLocation.x - lens.center.x, value.startLocation.y - lens.center.y) <= lens.radius + 12 else { return }
                    dragOrigin = current; dragSideOrigin = currentSide
                }
                let travel = max(1, size.height * 0.48 + 24)
                let raw = (dragOrigin ?? 1) - Double(value.translation.height) / travel
                dragProgress = WelcomeGlassGeometry.rubberBand(raw)
                let limit = WelcomeGlassGeometry.sideLimit(size: size)
                dragSide = max(-limit, min(limit, dragSideOrigin + limit * tanh(Double(value.translation.width) / limit)))
            }
            .onEnded { value in
                guard dragOrigin != nil else { return }
                let time = logicalTime(at: Date())
                let travel = max(1, size.height * 0.48 + 24)
                let current = dragProgress ?? vertical.sample(at: time).value
                let projected = (dragOrigin ?? current) - Double(value.predictedEndTranslation.height) / travel
                let velocity = max(-3.5, min(3.5, -Double(value.predictedEndTranslation.height - value.translation.height) / travel / 0.18))
                vertical = WelcomeGlassSpring(from: current, to: projected > 0.46 ? 1 : 0, velocity: velocity, started: time)
                horizontal = WelcomeGlassSpring(from: dragSide, to: 0, velocity: 0, started: time)
                dragOrigin = nil; dragProgress = nil
            }
    }
}

/// Analytic damped spring: a new grab samples the current presentation, not an old target.
struct WelcomeGlassSpring {
    let from: Double
    let to: Double
    let velocity: Double
    let started: Double
    func sample(at time: Double) -> (value: Double, velocity: Double) {
        let t = max(0, time - started)
        if t > 2.2 { return (to, 0) }
        let decay = 8.8
        let frequency = 8.4
        let a = from - to
        let b = (velocity + decay * a) / frequency
        let wave = a * cos(frequency * t) + b * sin(frequency * t)
        let envelope = exp(-decay * t)
        let speed = envelope * (-decay * wave - a * frequency * sin(frequency * t) + b * frequency * cos(frequency * t))
        return (to + envelope * wave, speed)
    }
}

struct WelcomeGlassGeometry {
    let center: CGPoint
    let radius: CGFloat
    init(size: CGSize, progress: Double, side: Double) {
        let p = max(-0.08, min(1.10, progress))
        let settledRadius = min(size.width * 0.30, size.height * 0.31)
        let domeRadius = min(size.width * 0.72, size.height * 0.82)
        center = CGPoint(x: size.width * 0.52 + side,
                         y: size.height + 24 - (size.height * 0.48 + 24) * p)
        radius = max(40, domeRadius + (settledRadius - domeRadius) * p)
    }
    static func rubberBand(_ value: Double) -> Double {
        if value < 0 { return -0.08 * (1 - exp(value / 0.20)) }
        if value > 1 { return 1 + 0.10 * (1 - exp(-(value - 1) / 0.20)) }
        return value
    }
    static func sideLimit(size: CGSize) -> Double {
        max(12, min(72, Double(size.width * 0.48 - min(size.width * 0.30, size.height * 0.31) - 20)))
    }
}

private struct WelcomeGlassArtwork: View {
    let size: CGSize
    let time: Double
    let lens: WelcomeGlassGeometry
    let shaderEnabled: Bool
    let force: Double
    let night: Bool
    var body: some View {
        Group {
            if shaderEnabled {
                WelcomeGlassCanvas(time: time, night: night)
                    .layerEffect(Shader(function: ShaderFunction(library: .default, name: "zhihuiWelcomeGlass"), arguments: [
                        .float2(size), .float2(lens.center), .float(lens.radius), .float(time), .float(force), .float(night ? 1.0 : 0.0)
                    ]), maxSampleOffset: CGSize(width: 48, height: 48))
            } else {
                WelcomeGlassCanvas(time: 0, night: night)
                    .overlay {
                        Circle().fill(Design.soft)
                            .overlay { Circle().strokeBorder(Design.accent.opacity(0.45), lineWidth: 1.5) }
                            .overlay { Image(systemName: "waveform").font(.system(size: 56, weight: .light)).foregroundStyle(Design.accent) }
                            .frame(width: lens.radius * 2, height: lens.radius * 2)
                            .position(lens.center)
                    }
            }
        }
    }
}

/// Everything here is original decorative Canvas content; it never represents saved user data.
private struct WelcomeGlassCanvas: View {
    let time: Double
    let night: Bool
    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Design.soft))
            let center = CGPoint(x: size.width * 0.52, y: size.height * 0.50)
            let wash = Path(ellipseIn: CGRect(x: center.x - 250, y: center.y - 210, width: 500, height: 420))
            context.fill(wash, with: .radialGradient(Gradient(colors: [Design.accent.opacity(night ? 0.14 : 0.06), .clear]), center: center, startRadius: 0, endRadius: 260))
            var grid = Path()
            for x in stride(from: CGFloat(28), to: size.width, by: 44) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: CGFloat(28), to: size.height, by: 44) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(grid, with: .color(Design.accent.opacity(0.055)), lineWidth: 0.6)
            drawConnections(context: &context, size: size)
            drawCard(context: &context, center: CGPoint(x: size.width * 0.25, y: size.height * 0.23 + sin(time * 0.72) * 4),
                     size: CGSize(width: 176, height: 100), angle: -0.065, kind: .voice)
            drawCard(context: &context, center: CGPoint(x: size.width * 0.72, y: size.height * 0.31 + cos(time * 0.63) * 4),
                     size: CGSize(width: 186, height: 114), angle: 0.055, kind: .note)
            drawCard(context: &context, center: CGPoint(x: size.width * 0.76, y: size.height * 0.74 + sin(time * 0.60 + 1) * 4),
                     size: CGSize(width: 150, height: 96), angle: -0.045, kind: .file)
            drawCard(context: &context, center: CGPoint(x: size.width * 0.28, y: size.height * 0.72 + cos(time * 0.68 + 1) * 4),
                     size: CGSize(width: 190, height: 112), angle: 0.035, kind: .question)
            var mark = Path()
            let heights: [CGFloat] = [14, 25, 37, 25, 14]
            for (index, height) in heights.enumerated() {
                mark.addRoundedRect(in: CGRect(x: center.x - 26 + CGFloat(index) * 12, y: center.y - height / 2, width: 5, height: height), cornerSize: CGSize(width: 2.5, height: 2.5))
            }
            context.fill(mark, with: .color(Design.accent.opacity(0.75)))
        }
    }
    private enum CardKind { case voice, note, file, question }
    private func drawConnections(context: inout GraphicsContext, size: CGSize) {
        let nodes = [CGPoint(x: size.width * 0.25, y: size.height * 0.23), CGPoint(x: size.width * 0.72, y: size.height * 0.31), CGPoint(x: size.width * 0.76, y: size.height * 0.74), CGPoint(x: size.width * 0.28, y: size.height * 0.72)]
        let center = CGPoint(x: size.width * 0.52, y: size.height * 0.50)
        for node in nodes {
            var path = Path(); path.move(to: node)
            path.addQuadCurve(to: center, control: CGPoint(x: node.x, y: center.y))
            context.stroke(path, with: .color(Design.accent.opacity(0.16)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
        }
    }
    private func drawCard(context: inout GraphicsContext, center: CGPoint, size: CGSize, angle: Double, kind: CardKind) {
        var card = context
        card.translateBy(x: center.x, y: center.y); card.rotate(by: .radians(angle))
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let shape = Path(roundedRect: rect, cornerRadius: 16)
        card.fill(shape, with: .color(Design.surface))
        card.stroke(shape, with: .color(Design.line.opacity(0.65)), lineWidth: 1)
        let left = rect.minX + 16
        let top = rect.minY + 16
        let title: String
        switch kind { case .voice: title = "讨论正在发生"; case .note: title = "会议笔记"; case .file: title = "项目资料"; case .question: title = "向会议提问" }
        card.draw(Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Design.ink), at: CGPoint(x: left, y: top), anchor: .topLeading)
        switch kind {
        case .voice:
            var bars = Path()
            for index in 0..<20 {
                let height = 7 + CGFloat(0.5 + 0.5 * sin(Double(index) * 0.92 + time * 1.15)) * 25
                bars.addRoundedRect(in: CGRect(x: left + CGFloat(index) * 7.1, y: top + 29 + (32 - height) / 2, width: 3.2, height: height), cornerSize: CGSize(width: 1.6, height: 1.6))
            }
            card.fill(bars, with: .color(Design.accent))
        case .note:
            card.draw(Text("决定与行动项").font(.system(size: 13)).foregroundStyle(Design.muted), at: CGPoint(x: left, y: top + 25), anchor: .topLeading)
            for (index, width) in [120.0, 145.0, 90.0].enumerated() {
                let line = Path(roundedRect: CGRect(x: left, y: top + 50 + Double(index) * 13, width: width, height: 4), cornerRadius: 2)
                card.fill(line, with: .color(Design.accent.opacity(index == 2 ? 0.28 : 0.13)))
            }
        case .file:
            card.draw(Text("方案与参考文件").font(.system(size: 13)).foregroundStyle(Design.muted), at: CGPoint(x: left, y: top + 25), anchor: .topLeading)
            var line = Path(); line.move(to: CGPoint(x: left, y: top + 57)); line.addLine(to: CGPoint(x: left + 92, y: top + 57))
            card.stroke(line, with: .color(Design.accent.opacity(0.35)), lineWidth: 4)
        case .question:
            card.draw(Text("下一步由谁负责？").font(.system(size: 13)).foregroundStyle(Design.ink), at: CGPoint(x: left, y: top + 28), anchor: .topLeading)
            card.draw(Text("从原文中寻找答案").font(.system(size: 13)).foregroundStyle(Design.muted), at: CGPoint(x: left, y: top + 57), anchor: .topLeading)
        }
    }
}
