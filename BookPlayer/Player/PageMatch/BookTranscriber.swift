//
//  BookTranscriber.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//
//  Audio → word-timestamped transcript, on device, with WhisperKit (Core ML / Neural Engine).
//  Add the package: https://github.com/argmaxinc/WhisperKit
//
//  Runs once per book. Audio is read in 10-minute slices so a 20-hour book never has to sit
//  in memory (a whole 20-hour book at 16 kHz would be ~4.6 GB of samples).
//

import AVFoundation
import Foundation
import WhisperKit

/// One audio file of a book and where it starts on the book's timeline.
/// Single-file book: one part at 0. Multi-file ("bound") book: one per file.
public struct AudioPart: Sendable {
  public let url: URL
  public let bookStart: TimeInterval

  public init(url: URL, bookStart: TimeInterval) {
    self.url = url
    self.bookStart = bookStart
  }
}

public actor BookTranscriber {
  public let model: String
  private var whisper: WhisperKit?
  private let sliceLength: TimeInterval = 600

  /// `base.en` is plenty: the matcher shrugs off a few wrong words, and it is several times
  /// faster than `small.en`. Pick a multilingual model ("base") for non-English books.
  public init(model: String = "base.en") {
    self.model = model
  }

  public func transcribe(
    parts: [AudioPart],
    bookUUID: String,
    duration: TimeInterval,
    progress: @Sendable (Double) -> Void = { _ in }
  ) async throws -> BookTranscript {
    let whisper = try await loadModel()
    let options = DecodingOptions(
      language: model.hasSuffix(".en") ? "en" : nil,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: true,
      chunkingStrategy: .vad          // split each slice on silences, decode chunks in parallel
    )

    var words: [TranscriptWord] = []
    words.reserveCapacity(Int(duration * 2.6))   // narrators average ~155 words/min

    for part in parts {
      let fileDuration = try Self.duration(of: part.url)
      var sliceStart: TimeInterval = 0
      while sliceStart < fileDuration {
        try Task.checkCancellation()
        let sliceEnd = min(sliceStart + sliceLength, fileDuration)
        let samples = try AudioProcessor.loadAudioAsFloatArray(
          fromPath: part.url.path,
          startTime: sliceStart,
          endTime: sliceEnd
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let offset = part.bookStart + sliceStart
        for word in results.flatMap(\.segments).flatMap({ $0.words ?? [] }) {
          let text = word.word.trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { continue }
          words.append(TranscriptWord(
            text: text,
            start: offset + TimeInterval(word.start),
            end: offset + TimeInterval(word.end)
          ))
        }
        sliceStart = sliceEnd
        progress(min(1, (words.last?.end ?? 0) / max(duration, 1)))
      }
    }

    words.sort { $0.start < $1.start }   // parallel chunks can return slightly out of order
    return BookTranscript(bookUUID: bookUUID, duration: duration, model: model, words: words)
  }

  private func loadModel() async throws -> WhisperKit {
    if let whisper { return whisper }
    // First run downloads the model (~150 MB for base.en) from Hugging Face.
    let loaded = try await WhisperKit(WhisperKitConfig(model: model))
    whisper = loaded
    return loaded
  }

  private static func duration(of url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
  }
}
