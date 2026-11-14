//
//  PageMatchView.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import PhotosUI
import SwiftUI
import UIKit

/// Page Match, shown as a sheet over the player. The sheet provides the navigation stack and
/// the close button; `onPlay` closes it once playback moves to the matched spot.
struct PageMatchView: View {
  @StateObject private var model: PageMatchViewModel
  @StateObject private var theme = ThemeViewModel()
  @State private var showsCamera = false
  @State private var photoItem: PhotosPickerItem?
  private let onPlay: () -> Void

  init(onPlay: @escaping () -> Void = {}, initModel: @escaping () -> PageMatchViewModel) {
    self.onPlay = onPlay
    self._model = .init(wrappedValue: initModel())
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.systemBackgroundColor)
      .navigationTitle("page_match_title")
      .navigationBarTitleDisplayMode(.inline)
      .task { await model.load() }
      .onDisappear { model.stop() }
      .fullScreenCover(isPresented: $showsCamera) {
        CameraCapture { image in
          showsCamera = false
          if let image { Task { await model.scan(image) } }
        }
        .ignoresSafeArea()
      }
      .onChange(of: photoItem) {
        guard let item = photoItem else { return }
        photoItem = nil
        Task {
          if let data = try? await item.loadTransferable(type: Data.self),
             let image = UIImage(data: data) {
            await model.scan(image)
          }
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView()
    case .unavailable:
      message(
        icon: "icloud.slash",
        title: "page_match_unavailable_title",
        body: "page_match_unavailable_description"
      )
    case .needsTranscript:
      prepareView
    case .transcribing(let progress):
      transcribingView(progress)
    case .ready:
      readyView
    case .matching:
      VStack(spacing: Spacing.S1) {
        ProgressView()
        Text("page_match_matching")
          .bpFont(.body)
          .foregroundStyle(theme.secondaryColor)
      }
      .accessibilityElement(children: .combine)
    case .matched(let result):
      resultView(result)
    case .notFound:
      VStack(spacing: Spacing.M) {
        message(
          icon: "doc.text.magnifyingglass",
          title: "page_match_not_found_title",
          body: "page_match_not_found_description"
        )
        scanButtons
      }
    case .failed(let error):
      VStack(spacing: Spacing.M) {
        message(icon: "exclamationmark.triangle", title: "page_match_failed_title", body: LocalizedStringKey(error))
        Button("page_match_retry_button") { model.prepareBook() }
          .buttonStyle(.borderedProminent)
          .tint(theme.linkColor)
      }
    }
  }

  // MARK: - States

  private var prepareView: some View {
    ScrollView {
      VStack(spacing: Spacing.M) {
        message(
          icon: "text.viewfinder",
          title: "page_match_intro_title",
          body: "page_match_intro_description"
        )
        Text("page_match_prepare_description")
          .bpFont(.footnote)
          .foregroundStyle(theme.secondaryColor)
          .multilineTextAlignment(.center)
        Button {
          model.prepareBook()
        } label: {
          Text("page_match_prepare_button")
            .bpFont(.title)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(theme.linkColor)
      }
      .padding(Spacing.M)
    }
  }

  private func transcribingView(_ progress: Double) -> some View {
    VStack(spacing: Spacing.M) {
      Image(systemName: "waveform")
        .font(.largeTitle)
        .foregroundStyle(theme.linkColor)
        .symbolEffect(.variableColor.iterative)
        .accessibilityHidden(true)
      Text(String.localizedStringWithFormat("page_match_preparing".localized, Int(progress * 100)))
        .bpFont(.title)
        .foregroundStyle(theme.primaryColor)
      ProgressView(value: progress)
        .tint(theme.linkColor)
        .accessibilityHidden(true)
      Text("page_match_keep_open")
        .bpFont(.footnote)
        .foregroundStyle(theme.secondaryColor)
        .multilineTextAlignment(.center)
      Button("cancel_button", role: .cancel) { model.cancelTranscription() }
        .foregroundStyle(theme.linkColor)
    }
    .padding(Spacing.M)
  }

  private var readyView: some View {
    ScrollView {
      VStack(spacing: Spacing.M) {
        message(
          icon: "text.viewfinder",
          title: "page_match_ready_title",
          body: "page_match_ready_description"
        )
        scanButtons
        if let passage = model.currentPassage {
          VStack(alignment: .leading, spacing: Spacing.S2) {
            Text("page_match_now_reading")
              .bpFont(.captionSemibold)
              .foregroundStyle(theme.secondaryColor)
              .textCase(.uppercase)
            Text(verbatim: "“\(passage)…”")
              .bpFont(.body)
              .italic()
              .foregroundStyle(theme.primaryColor)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Spacing.S)
          .background(theme.secondarySystemBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
          .accessibilityElement(children: .combine)
        }
      }
      .padding(Spacing.M)
    }
  }

  private var scanButtons: some View {
    VStack(spacing: Spacing.S1) {
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button {
          showsCamera = true
        } label: {
          Label("page_match_scan_button", systemImage: "camera.viewfinder")
            .bpFont(.title)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(theme.linkColor)
      }
      PhotosPicker(selection: $photoItem, matching: .images) {
        Label("page_match_photo_button", systemImage: "photo.on.rectangle")
          .bpFont(.title)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .tint(theme.linkColor)
    }
  }

  private func resultView(_ result: PageMatchViewModel.Result) -> some View {
    List {
      Section {
        ForEach(Array(result.lines.enumerated()), id: \.offset) { index, line in
          lineRow(line, time: result.lineTimes[index]) {
            model.play(result, line: index)
            onPlay()
          }
        }
      } header: {
        Text("page_match_pick_line")
          .bpFont(.caption)
          .foregroundStyle(theme.secondaryColor)
      }
    }
    .listStyle(.plain)
    .applyListStyle(with: theme, background: theme.systemBackgroundColor)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: Spacing.S2) {
        Button {
          model.play(result)
          onPlay()
        } label: {
          Label(
            String.localizedStringWithFormat("page_match_play_button".localized, TimeParser.formatTime(result.time)),
            systemImage: "play.fill"
          )
          .bpFont(.title)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(theme.linkColor)
        Button("page_match_scan_again_button") { model.scanAgain() }
          .foregroundStyle(theme.linkColor)
      }
      .padding(Spacing.S)
      .background(.bar)
    }
  }

  @ViewBuilder
  private func lineRow(_ line: String, time: TimeInterval?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline) {
        Text(line)
          .bpFont(.body)
          .foregroundStyle(time == nil ? theme.secondaryColor : theme.primaryColor)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let time {
          Text(TimeParser.formatTime(time))
            .bpFont(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.secondaryColor)
        }
      }
    }
    .disabled(time == nil)
    .listRowBackground(theme.systemBackgroundColor)
    .accessibilityHint("page_match_line_hint")
  }

  private func message(icon: String, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
    VStack(spacing: Spacing.S1) {
      Image(systemName: icon)
        .font(.largeTitle)
        .foregroundStyle(theme.linkColor)
        .accessibilityHidden(true)
      Text(title)
        .bpFont(.titleLarge)
        .foregroundStyle(theme.primaryColor)
        .multilineTextAlignment(.center)
      Text(body)
        .bpFont(.body)
        .foregroundStyle(theme.secondaryColor)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, Spacing.S)
    .accessibilityElement(children: .combine)
  }
}

/// The system camera, returning one photo (nil on cancel)
private struct CameraCapture: UIViewControllerRepresentable {
  let onFinish: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let onFinish: (UIImage?) -> Void

    init(onFinish: @escaping (UIImage?) -> Void) {
      self.onFinish = onFinish
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      onFinish(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onFinish(nil)
    }
  }
}
