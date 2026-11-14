//
//  PageMatchViewModel.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//
//  Page Match: scan a page of the printed book (or an e-reader screen) and jump to that spot
//  in the audiobook. One-time per book, the audio is transcribed on device (BookTranscriber);
//  every scan after that is OCR (PageScanner) + text matching (PageMatcher), well under a second.
//

import BookPlayerKit
import CoreGraphics
import Foundation
import ImageIO
import UIKit

extension PlayableItem {
  /// The local audio files behind this book, each placed on the book's timeline.
  /// nil for a streamed book (Jellyfin / AudiobookShelf) or one not downloaded to this device:
  /// there's no local file to transcribe.
  var pageMatchAudioParts: [AudioPart]? {
    let isLocal: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    guard isBoundBook else {
      guard chapters.first?.isStreamed != true, isLocal(fileURL) else { return nil }
      return [AudioPart(url: fileURL, bookStart: 0)]
    }
    var seen = Set<String>()
    var parts: [AudioPart] = []
    for chapter in chapters where seen.insert(chapter.relativePath).inserted {
      guard !chapter.isStreamed, isLocal(chapter.fileURL) else { return nil }
      // PlayableItem.getChapterTime: fileTime = bookTime − start + chapterOffset
      parts.append(AudioPart(url: chapter.fileURL, bookStart: chapter.start - chapter.chapterOffset))
    }
    return parts
  }
}

@MainActor
final class PageMatchViewModel: ObservableObject {
  struct Result: Equatable {
    let lines: [String]
    let lineTimes: [TimeInterval?]
    let time: TimeInterval
  }

  enum Phase: Equatable {
    case loading
    /// Nothing loaded, or a streamed book
    case unavailable
    /// Offer the one-time "Prepare this book" step
    case needsTranscript
    case transcribing(progress: Double)
    case ready
    case matching
    case matched(Result)
    case notFound
    case failed(String)
  }

  @Published private(set) var phase: Phase = .loading

  private let playerManager: PlayerManagerProtocol
  private let transcriber = BookTranscriber()
  private var matcher: PageMatcher?
  private var transcriptionTask: Task<Void, Never>?
  private var idleTimerWasDisabled = false

  init(playerManager: PlayerManagerProtocol) {
    self.playerManager = playerManager
  }

  var bookTitle: String { playerManager.currentItem?.title ?? "" }

  /// The words being spoken now, for finding your place on the page ("listen → read")
  var currentPassage: String? {
    guard let matcher, let item = playerManager.currentItem else { return nil }
    let passage = matcher.passage(at: item.currentTime)
    return passage.isEmpty ? nil : passage
  }

  // MARK: - Lifecycle

  func load() async {
    guard let item = playerManager.currentItem, item.pageMatchAudioParts != nil else {
      phase = .unavailable
      return
    }
    let uuid = item.uuid
    let duration = item.duration
    let matcher = await Task.detached(priority: .userInitiated) { () -> PageMatcher? in
      // A transcript of a replaced file (different length) is stale
      guard let transcript = BookTranscript.load(bookUUID: uuid),
            abs(transcript.duration - duration) < 1 else { return nil }
      return PageMatcher(transcript: transcript)
    }.value
    self.matcher = matcher
    phase = matcher == nil ? .needsTranscript : .ready
  }

  /// Called when the sheet goes away: a transcription stops with it.
  func stop() {
    cancelTranscription()
  }

  // MARK: - One-time transcription

  func prepareBook() {
    guard transcriptionTask == nil,
          let item = playerManager.currentItem,
          let parts = item.pageMatchAudioParts else { return }

    phase = .transcribing(progress: 0)
    keepScreenAwake(true)

    let uuid = item.uuid
    let duration = item.duration
    transcriptionTask = Task { [weak self, transcriber] in
      do {
        let transcript = try await transcriber.transcribe(
          parts: parts,
          bookUUID: uuid,
          duration: duration
        ) { fraction in
          Task { @MainActor [weak self] in
            guard let self, case .transcribing = self.phase else { return }
            self.phase = .transcribing(progress: fraction)
          }
        }
        let matcher = try await Task.detached(priority: .userInitiated) { () throws -> PageMatcher in
          try transcript.save()
          return PageMatcher(transcript: transcript)
        }.value
        self?.finishTranscription(with: matcher)
      } catch is CancellationError {
        self?.finishTranscription(with: nil)
      } catch {
        self?.finishTranscription(with: nil, error: error)
      }
    }
  }

  func cancelTranscription() {
    transcriptionTask?.cancel()
  }

  private func finishTranscription(with matcher: PageMatcher?, error: Error? = nil) {
    transcriptionTask = nil
    keepScreenAwake(false)
    self.matcher = matcher
    if matcher != nil {
      phase = .ready
    } else if let error {
      phase = .failed(error.localizedDescription)
    } else {
      phase = .needsTranscript
    }
  }

  /// A long book takes a while: keep the screen on so iOS doesn't suspend the work.
  private func keepScreenAwake(_ awake: Bool) {
    if awake {
      idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
    } else {
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }
  }

  // MARK: - Scanning

  func scan(_ image: UIImage) async {
    guard let matcher, let cgImage = image.cgImage else { return }
    phase = .matching
    do {
      let lines = try await PageScanner.lines(
        in: cgImage,
        orientation: CGImagePropertyOrientation(image.imageOrientation)
      )
      let match = await Task.detached(priority: .userInitiated) { matcher.match(lines: lines) }.value
      guard let match, match.isReliable else {
        phase = .notFound
        return
      }
      phase = .matched(Result(lines: lines, lineTimes: match.lineTimes, time: match.time))
    } catch {
      phase = .notFound
    }
  }

  func scanAgain() {
    phase = matcher == nil ? .needsTranscript : .ready
  }

  /// Plays from the top of the page, or from the line the reader tapped. `jumpTo` records an
  /// automatic bookmark first, so a wrong match is one tap to undo.
  func play(_ result: Result, line: Int? = nil) {
    let time = line.flatMap { result.lineTimes[$0] } ?? result.time
    playerManager.jumpTo(max(0, time - 1), recordBookmark: true)  // 1 s lead-in
    if !playerManager.isPlaying {
      playerManager.play()
    }
  }
}

extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .upMirrored: self = .upMirrored
    case .down: self = .down
    case .downMirrored: self = .downMirrored
    case .left: self = .left
    case .leftMirrored: self = .leftMirrored
    case .right: self = .right
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
