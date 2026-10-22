/*
    This file is part of the darktable iPadOS tethering test app.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

import SwiftUI

@main
struct TetherTestApp: App {
  @StateObject private var model = SpikeModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: SpikeModel
  @State private var resultsURL: URL?

  var body: some View {
    HStack(spacing: 0) {
      stepList
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 460)
      Divider()
      VStack(spacing: 8) {
        header
        HStack(alignment: .top, spacing: 8) {
          liveView
          controls.frame(width: 240)
        }
        logView
      }
      .padding(8)
    }
  }

  // MARK: steps

  private var stepList: some View {
    List {
      Section {
        ForEach(model.steps) { step in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("\(step.id). \(step.title)").font(.headline)
              Spacer()
              badge(step.status)
              Button(buttonTitle(step)) { model.run(step.id) }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy && step.id != 8)
            }
            Text(step.question).font(.subheadline).foregroundColor(.secondary)
            if !step.detail.isEmpty {
              Text(step.detail).font(.caption).textSelection(.enabled)
            }
            if step.status == .fail {
              Text("If it fails: \(step.ifFails)").font(.caption).foregroundColor(.orange)
            }
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("One-day spike, run in order")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Receive-only download (fallback 1)", isOn: $model.receiveOnlyDownload)
          Toggle("Wrap sent data in a PTP container", isOn: $model.wrapOutData)
          Toggle("Log every PTP command", isOn: $model.verbose)
          HStack {
            Button("Save results") { resultsURL = model.writeResults() }
            if let url = resultsURL {
              ShareLink(item: url) { Label("Share results", systemImage: "square.and.arrow.up") }
            }
            ShareLink(item: model.logURL) { Label("Share log", systemImage: "doc.text") }
          }
          Text("Captures, results and logs are also in the Files app under On My iPad > TetherTest.")
            .font(.caption2)
        }
        .padding(.top, 8)
      }
    }
    .listStyle(.insetGrouped)
  }

  private func buttonTitle(_ step: StepResult) -> String {
    if step.id == 8 { return model.heartbeatRunning ? "Stop" : "Start" }
    return step.status == .notRun ? "Run" : "Again"
  }

  private func badge(_ status: StepStatus) -> some View {
    let color: Color
    switch status {
    case .pass: color = .green
    case .fail: color = .red
    case .partial: color = .orange
    case .running: color = .blue
    case .notRun: color = .gray
    }
    return Text(status.rawValue)
      .font(.caption.bold())
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.2))
      .foregroundColor(color)
      .clipShape(Capsule())
  }

  // MARK: right side

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.deviceLine).font(.caption).lineLimit(2)
      if !model.authLine.isEmpty { Text(model.authLine).font(.caption) }
      if !model.heartbeatLine.isEmpty { Text("Heartbeat: \(model.heartbeatLine)").font(.caption) }
      Text("iPadOS \(SpikeModel.osBuild)").font(.caption2).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var liveView: some View {
    ZStack(alignment: .topLeading) {
      Rectangle().fill(Color.black)
      if let img = model.liveImage ?? model.lastCaptureImage {
        Image(uiImage: img).resizable().scaledToFit()
      } else {
        Text("no image yet").foregroundColor(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      VStack(alignment: .leading) {
        if !model.liveFPS.isEmpty { Text(model.liveFPS) }
        if !model.lastCaptureName.isEmpty { Text(model.lastCaptureName) }
      }
      .font(.caption.monospaced())
      .foregroundColor(.white)
      .padding(6)
    }
    .aspectRatio(3.0 / 2.0, contentMode: .fit)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { model.captureNow() } label: {
        Label("Capture", systemImage: "camera.aperture").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.busy)

      Button { model.toggleLiveView() } label: {
        Label(model.liveRunning ? "Stop live view" : "Live view", systemImage: "video")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(model.busy && !model.liveRunning)

      nudgeRow("ISO", PTPProp.sonyISO, minus: "-", plus: "+")
      nudgeRow("Shutter", PTPProp.sonyShutterSpeed, minus: "slower", plus: "faster")

      ForEach(model.readouts.indices, id: \.self) { i in
        HStack {
          Text(model.readouts[i].0).foregroundColor(.secondary)
          Spacer()
          Text(model.readouts[i].1)
        }
        .font(.caption)
      }

      HStack {
        Button("Refresh") { model.updateReadouts() }
        Button("Log all props") { model.dumpProps() }.disabled(model.busy)
      }
      .font(.caption)
    }
  }

  private func nudgeRow(_ name: String, _ prop: UInt16, minus: String, plus: String) -> some View {
    HStack {
      Text(name).font(.caption)
      Spacer()
      Button(minus) { model.nudge(prop, -1) }.disabled(model.busy)
      Button(plus) { model.nudge(prop, 1) }.disabled(model.busy)
    }
    .buttonStyle(.bordered)
  }

  private var logView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(model.log.indices, id: \.self) { i in
            Text(model.log[i])
              .font(.system(size: 11, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(i)
          }
        }
        .textSelection(.enabled)
      }
      .background(Color(UIColor.secondarySystemBackground))
      .onChange(of: model.log.count) { count in
        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
      }
    }
  }
}
