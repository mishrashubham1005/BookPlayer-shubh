//
//  BookTranscript.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//
//  The data model: one transcript per audiobook, with a timestamp for every word.
//  Produced once (on-device by BookTranscriber, or on a Mac), then reused for every scan.
//

import Foundation

/// One spoken word. `start` / `end` are seconds in *book time* (the same timeline
/// `PlayerManager.jumpTo(_:)` and `PlayableItem.currentTime` use), not file time.
public struct TranscriptWord: Codable, Sendable, Equatable {
  public let text: String
  public let start: TimeInterval
  public let end: TimeInterval

  public init(text: String, start: TimeInterval, end: TimeInterval) {
    self.text = text
    self.start = start
    self.end = end
  }
}

public struct BookTranscript: Codable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public let bookUUID: String
  /// Lets us detect a re-imported or replaced audio file and re-transcribe.
  public let duration: TimeInterval
  public let model: String
  public var words: [TranscriptWord]

  public init(bookUUID: String, duration: TimeInterval, model: String, words: [TranscriptWord]) {
    self.version = Self.currentVersion
    self.bookUUID = bookUUID
    self.duration = duration
    self.model = model
    self.words = words
  }
}

// MARK: - Storage

extension BookTranscript {
  /// Application Support, NOT Documents: BookPlayer imports whatever lands in Documents,
  /// so a transcript saved there would show up as a "book".
  public static func url(for bookUUID: String) throws -> URL {
    let dir = try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("PageMatch", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Re-creatable data: keep the whole folder out of iCloud backups.
    var folder = dir
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)
    return dir.appendingPathComponent("\(bookUUID).json")
  }

  public static func load(bookUUID: String) -> BookTranscript? {
    guard let fileURL = try? Self.url(for: bookUUID),
          let data = try? Data(contentsOf: fileURL),
          let transcript = try? JSONDecoder().decode(BookTranscript.self, from: data),
          transcript.version == currentVersion
    else { return nil }
    return transcript
  }

  public func save() throws {
    let data = try JSONEncoder().encode(self)
    try data.write(to: try Self.url(for: bookUUID), options: .atomic)
  }
}

// MARK: - Text normalisation (shared by transcript and page text)

enum TextNormalizer {
  /// "Don’t", "DON'T", "don't," → "dont". Accents folded, punctuation dropped.
  static func normalize<S: StringProtocol>(_ raw: S) -> String? {
    let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return kept.isEmpty ? nil : String(String.UnicodeScalarView(kept))
  }

  /// Splits on whitespace, hyphens, dashes and slashes so "well-known" and "well known"
  /// tokenise the same way whichever form Whisper or the printed book uses.
  static func tokenize(_ text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace || separators.contains($0) })
      .compactMap { normalize($0) }
  }

  private static let separators: Set<Character> = ["-", "‐", "‑", "‒", "–", "—", "―", "/"]
}
