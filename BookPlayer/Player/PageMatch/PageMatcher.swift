//
//  PageMatcher.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//
//  Finds where a scanned page is in the audiobook.
//
//  Two passes:
//   1. Coarse — "Shazam for text". Every run of 4 words on the page that also appears in the
//      transcript casts a vote for an offset (transcript position − page position). The page's
//      true location is the densest cluster of votes. Rare phrases count more than common ones.
//      Cost: a few dictionary lookups, so it stays fast on a 25-hour book.
//   2. Fine — a fuzzy word-by-word alignment (Smith-Waterman style) of the page against a
//      small transcript window around the winner. This absorbs OCR typos and Whisper errors
//      and gives a timestamp for every line on the page.
//
//  Everything is plain Swift with no dependencies, so it can be unit-tested without a device.
//

import Foundation

public struct PageMatch: Sendable {
  /// Where the first line of the page is spoken, in book time.
  public let time: TimeInterval
  /// One entry per input line: when that line starts (nil if it couldn't be aligned).
  /// Lets the UI offer "tap the line you're on" instead of always starting at the top.
  public let lineTimes: [TimeInterval?]
  /// Share of the page's 4-word phrases that voted for the winning spot.
  public let confidence: Double
  /// Share of the page's words aligned to transcript words.
  public let matchedFraction: Double
  /// 0…1: how strong the best *other* location was compared with the winner. High = ambiguous.
  public let ambiguity: Double

  /// Thresholds from simulation. Full pages separate cleanly (right book ≥ 0.87 matched,
  /// wrong book ≤ 0.14). Short snippets of 15 words are the risky case, where a phrase from
  /// another book by the same author can look like a hit; 0.6 rejects nearly all of those.
  public var isReliable: Bool { matchedFraction >= 0.6 && confidence >= 0.05 && ambiguity < 0.6 }
}

public final class PageMatcher: Sendable {
  // Tuning knobs (values validated in simulation, see README).
  static let shingle = 4
  static let fallbackShingle = 3
  static let maxOccurrences = 8        // phrases more common than this carry no location signal
  static let clusterWidth = 48         // tokens of drift allowed inside one vote cluster
  static let windowPad = 80            // extra transcript tokens either side for the fine pass
  static let minPageTokens = 8

  private let words: [TranscriptWord]
  private let tokens: [String]
  private let tokenWord: [Int32]       // token index → word index
  private let wordStarts: [TimeInterval]
  private let index4: [Int: [Int32]]
  private let index3: [Int: [Int32]]

  /// Builds the lookup tables. ~150k words takes well under a second; do it off the main actor
  /// and keep the instance for as long as the book is open.
  public init(transcript: BookTranscript) {
    let words = transcript.words
    var tokens: [String] = []
    var tokenWord: [Int32] = []
    tokens.reserveCapacity(words.count)
    tokenWord.reserveCapacity(words.count)
    for (wordIndex, word) in words.enumerated() {
      for token in TextNormalizer.tokenize(word.text) {
        tokens.append(token)
        tokenWord.append(Int32(wordIndex))
      }
    }
    self.words = words
    self.tokens = tokens
    self.tokenWord = tokenWord
    self.wordStarts = words.map(\.start)
    self.index4 = Self.buildIndex(tokens, k: Self.shingle)
    self.index3 = Self.buildIndex(tokens, k: Self.fallbackShingle)
  }

  // MARK: Public API

  /// Page → audio. `lines` are the OCR'd lines of one page, top to bottom (see PageScanner).
  public func match(lines rawLines: [String]) -> PageMatch? {
    let lines = Self.joinHyphenatedLineBreaks(rawLines)
    var query: [String] = []
    var lineOfToken: [Int] = []
    for (lineIndex, line) in lines.enumerated() {
      for token in TextNormalizer.tokenize(line) {
        query.append(token)
        lineOfToken.append(lineIndex)
      }
    }
    guard query.count >= Self.minPageTokens else { return nil }

    // Pass 1: coarse location by phrase voting.
    var bestVote = Self.vote(query: query, k: Self.shingle, index: index4)
    if (bestVote?.confidence ?? 0) < 0.04,
       let fallback = Self.vote(query: query, k: Self.fallbackShingle, index: index3),
       fallback.confidence > (bestVote?.confidence ?? 0) {
      bestVote = fallback
    }
    guard let vote = bestVote else { return nil }

    // Pass 2: fuzzy alignment inside a small window.
    let lo = max(0, vote.offset - Self.windowPad)
    let hi = min(tokens.count, vote.offset + query.count + Self.windowPad)
    guard lo < hi else { return nil }
    let mapping = align(query: query, lo: lo, hi: hi)

    guard let first = mapping.firstIndex(where: { $0 != nil }), let anchor = mapping[first] else { return nil }
    // The page starts at the first line that aligned: lines that didn't align at all (a running
    // head the scanner kept) don't pull it earlier. Within that line, step back over any words
    // before the first aligned one.
    let firstLineStart = lineOfToken.firstIndex(of: lineOfToken[first]) ?? first
    let startToken = max(0, anchor - (first - firstLineStart))

    var lineTimes = [TimeInterval?](repeating: nil, count: lines.count)
    for (q, t) in mapping.enumerated() {
      guard let t, lineTimes[lineOfToken[q]] == nil else { continue }
      lineTimes[lineOfToken[q]] = time(ofToken: t)
    }

    let matched = Double(mapping.lazy.filter { $0 != nil }.count) / Double(query.count)
    return PageMatch(
      time: time(ofToken: startToken),
      lineTimes: lineTimes,
      confidence: vote.confidence,
      matchedFraction: matched,
      ambiguity: vote.ambiguity
    )
  }

  /// Audio → page ("Scan to read" in Spotify). Without the ebook we can't know the page
  /// number, so return the words being spoken; the reader looks for that sentence.
  public func passage(at time: TimeInterval, wordCount: Int = 14) -> String {
    guard !words.isEmpty else { return "" }
    // Last word starting at or before `time`.
    var lo = 0, hi = wordStarts.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if wordStarts[mid] <= time { lo = mid + 1 } else { hi = mid }
    }
    let start = max(0, lo - 1)
    return words[start..<min(words.count, start + wordCount)].map(\.text).joined(separator: " ")
  }

  // MARK: Pass 1 — voting

  private struct Vote {
    let offset: Int
    let confidence: Double
    let ambiguity: Double
  }

  private static func shingleKey<C: Collection>(_ slice: C) -> Int where C.Element == String {
    var hasher = Hasher()
    for token in slice { hasher.combine(token) }
    return hasher.finalize()
  }

  private static func buildIndex(_ tokens: [String], k: Int) -> [Int: [Int32]] {
    guard tokens.count >= k else { return [:] }
    var index: [Int: [Int32]] = [:]
    index.reserveCapacity(tokens.count)
    for i in 0...(tokens.count - k) {
      index[shingleKey(tokens[i..<(i + k)]), default: []].append(Int32(i))
    }
    return index
  }

  private static func vote(query: [String], k: Int, index: [Int: [Int32]]) -> Vote? {
    guard query.count >= k else { return nil }
    var hits: [(offset: Int, weight: Double)] = []
    for i in 0...(query.count - k) {
      guard let positions = index[shingleKey(query[i..<(i + k)])],
            positions.count <= maxOccurrences else { continue }
      let weight = 1.0 / Double(positions.count)
      for p in positions { hits.append((Int(p) - i, weight)) }
    }
    guard !hits.isEmpty else { return nil }
    hits.sort { $0.offset < $1.offset }

    // Sliding window over sorted offsets: every window of width `clusterWidth`.
    var windows: [(score: Double, lo: Int, hi: Int)] = []
    var left = 0
    var score = 0.0
    for right in hits.indices {
      score += hits[right].weight
      while hits[right].offset - hits[left].offset > clusterWidth {
        score -= hits[left].weight
        left += 1
      }
      windows.append((score, hits[left].offset, hits[right].offset))
    }
    windows.sort { $0.score > $1.score }
    let best = windows[0]
    let runnerUp = windows.dropFirst().first {
      $0.lo > best.hi + clusterWidth || $0.hi < best.lo - clusterWidth
    }?.score ?? 0

    let inside = hits.filter { $0.offset >= best.lo && $0.offset <= best.hi }
    let shingles = Double(max(1, query.count - k + 1))
    return Vote(
      offset: inside[inside.count / 2].offset,
      confidence: best.score / shingles,
      ambiguity: runnerUp / max(best.score, .ulpOfOne)
    )
  }

  // MARK: Pass 2 — alignment

  /// Semi-global alignment: the whole page against a window whose ends are free.
  /// Returns, for each page token, the transcript token it aligned to (or nil).
  private func align(query: [String], lo: Int, hi: Int) -> [Int?] {
    let window = Array(tokens[lo..<hi])
    let n = query.count, m = window.count
    let width = m + 1
    let gap = -1
    // Flat matrices: score and backpointer (0 diagonal, 1 skip page word, 2 skip transcript word).
    var score = [Int32](repeating: 0, count: (n + 1) * width)
    var back = [UInt8](repeating: 0, count: (n + 1) * width)
    for i in 1...n {
      score[i * width] = score[(i - 1) * width] + Int32(gap)
      back[i * width] = 1
    }
    let queryBytes = query.map { Array($0.utf8) }
    let windowBytes = window.map { Array($0.utf8) }

    for i in 1...n {
      for j in 1...m {
        let diag = score[(i - 1) * width + j - 1] + Int32(Self.similarity(queryBytes[i - 1], windowBytes[j - 1]))
        let up = score[(i - 1) * width + j] + Int32(gap)
        let left = score[i * width + j - 1] + Int32(gap)
        if diag >= up && diag >= left {
          score[i * width + j] = diag; back[i * width + j] = 0
        } else if up >= left {
          score[i * width + j] = up; back[i * width + j] = 1
        } else {
          score[i * width + j] = left; back[i * width + j] = 2
        }
      }
    }

    // Free end in the transcript: start the traceback from the best cell in the last row.
    var j = (0...m).max { score[n * width + $0] < score[n * width + $1] } ?? m
    var i = n
    var mapping = [Int?](repeating: nil, count: n)
    while i > 0 && j > 0 {
      switch back[i * width + j] {
      case 0:
        if Self.similarity(queryBytes[i - 1], windowBytes[j - 1]) > 0 { mapping[i - 1] = lo + j - 1 }
        i -= 1; j -= 1
      case 1: i -= 1
      default: j -= 1
      }
    }
    return mapping
  }

  /// +2 exact, +1 near-miss ("rnorning" vs "morning", "colour" vs "color"), −1 otherwise.
  private static func similarity(_ a: [UInt8], _ b: [UInt8]) -> Int {
    if a == b { return 2 }
    let shorter = min(a.count, b.count)
    guard shorter >= 4 else { return -1 }
    let limit = shorter < 8 ? 1 : 2
    return levenshtein(a, b, limit: limit) <= limit ? 1 : -1
  }

  private static func levenshtein(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
    if abs(a.count - b.count) > limit { return limit + 1 }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for (i, ca) in a.enumerated() {
      current[0] = i + 1
      for (j, cb) in b.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }

  // MARK: Helpers

  private func time(ofToken token: Int) -> TimeInterval {
    words[Int(tokenWord[min(token, tokenWord.count - 1)])].start
  }

  /// "some-" / "thing was" → "" / "something was", so the word lands on one line.
  static func joinHyphenatedLineBreaks(_ input: [String]) -> [String] {
    var lines = input.map { $0.trimmingCharacters(in: .whitespaces) }
    for i in lines.indices.dropLast() where lines[i].hasSuffix("-") && !lines[i + 1].isEmpty {
      let head = lines[i].dropLast()
      if let space = head.lastIndex(of: " ") {
        lines[i + 1] = String(head[head.index(after: space)...]) + lines[i + 1]
        lines[i] = String(head[..<space])
      } else {
        lines[i + 1] = String(head) + lines[i + 1]
        lines[i] = ""
      }
    }
    return lines
  }
}
