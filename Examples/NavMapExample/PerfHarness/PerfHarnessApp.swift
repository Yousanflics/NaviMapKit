//
//  PerfHarnessApp.swift
//  NavMapPerfHarness
//
//  Performance measurement rig (NOT frozen; the frozen artifact is
//  NavMapExampleIdeal.swift). Feeds Ownship a continuous 20 Hz circuit around
//  SFO and overlays a CADisplayLink-measured FPS readout, so a screen
//  recording/screenshot documents sustained frame rate under follow-camera
//  load. It also prints a per-second `perf-harness fps=…` line for log
//  capture.
//

import NaviAviationMapKit
import SwiftUI
import UIKit

@main
struct NavMapPerfHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            PerfScreen()
        }
    }
}

struct PerfScreen: View {
    @State private var viewport: NavigationViewport = .follow(.ownship, .courseUp)
    @StateObject private var fpsMonitor = FPSMonitor()

    private let feed = CircuitFeed()

    var body: some View {
        ZStack(alignment: .topLeading) {
            NaviMap(
                viewport: $viewport,
                profile: .aviation(.ifr)
            ) {
                NavigationBasemap(.operational)
                Ownship(source: feed.positions)
            }
            Text(String(format: "%.1f fps", fpsMonitor.fps))
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(fpsMonitor.fps >= 55 ? .green : .red)
                .padding(8)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 60)
                .padding(.leading, 16)
        }
        .ignoresSafeArea()
        .onAppear { fpsMonitor.start() }
    }
}

/// 20 Hz positions flying a left-hand circuit abeam SFO at ~120 kt.
struct CircuitFeed {
    var positions: AsyncStream<NavigationPosition> {
        AsyncStream { continuation in
            let task = Task {
                let centerLat = 37.6191
                let centerLon = -122.3816
                let radius = 0.03
                var angle = 0.0
                while !Task.isCancelled {
                    continuation.yield(NavigationPosition(
                        latitude: centerLat + radius * sin(angle),
                        longitude: centerLon + radius * cos(angle),
                        vertical: .msl(.init(value: 1200, unit: .feet))
                    ))
                    angle += 0.01
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class FPSMonitor: NSObject, ObservableObject {
    @Published var fps: Double = 0

    private var link: CADisplayLink?
    private var frameCount = 0
    private var windowStart = CACurrentMediaTime()

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        if elapsed >= 1 {
            fps = Double(frameCount) / elapsed
            print(String(format: "perf-harness fps=%.1f", fps))
            frameCount = 0
            windowStart = now
        }
    }
}
