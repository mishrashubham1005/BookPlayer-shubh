//
//  PageMatcherTests.swift
//  BookPlayerTests
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
import XCTest

/// Page Match's text matching, on a made-up 3-hour "book": a scanned page with OCR typos, a
/// running head and a hyphenated line break must still land on the right second.
final class PageMatcherTests: XCTestCase {
  private static let secondsPerWord: TimeInterval = 0.4
  private static let book = makeBook(wordCount: 27_000, seed: 1)
  private static let matcher = PageMatcher(transcript: transcript(of: book))

  func testFindsAPageWithOCRErrors() throws {
    let start = 18_200
    let lines = Self.scannedPage(Array(Self.book[start..<(start + 250)]))

    let match = try XCTUnwrap(Self.matcher.match(lines: ["143", "THE RIVER"] + lines))

    XCTAssertTrue(match.isReliable)
    XCTAssertEqual(match.time, Double(start) * Self.secondsPerWord, accuracy: 0.5)
  }

  func testGivesEachLineItsOwnTime() throws {
    let start = 4_000
    let lines = Self.scannedPage(Array(Self.book[start..<(start + 120)]))

    let match = try XCTUnwrap(Self.matcher.match(lines: lines))
    let times = match.lineTimes.compactMap { $0 }

    XCTAssertGreaterThanOrEqual(times.count, lines.count - 1)
    XCTAssertEqual(times, times.sorted(), "Lines further down the page play later")
    XCTAssertEqual(try XCTUnwrap(times.last), Double(start + 110) * Self.secondsPerWord, accuracy: 6)
  }

  func testFindsAShortChapterEnd() throws {
    let start = 9_990
    let match = try XCTUnwrap(Self.matcher.match(lines: [Self.book[start..<(start + 20)].joined(separator: " ")]))

    XCTAssertTrue(match.isReliable)
    XCTAssertEqual(match.time, Double(start) * Self.secondsPerWord, accuracy: 0.5)
  }

  func testRejectsAPageFromAnotherBook() {
    let otherBook = Self.makeBook(wordCount: 600, seed: 99)
    let match = Self.matcher.match(lines: Self.scannedPage(Array(otherBook[100..<350])))

    XCTAssertFalse(match?.isReliable ?? false)
  }

  func testNeedsEnoughText() {
    XCTAssertNil(Self.matcher.match(lines: ["Chapter", "12"]))
  }

  func testPassageAtTimeReturnsTheWordsBeingRead() {
    let passage = Self.matcher.passage(at: 500 * Self.secondsPerWord + 0.1, wordCount: 5)
    XCTAssertEqual(passage, Self.book[500..<505].joined(separator: " "))
  }

  func testJoinsWordsHyphenatedAcrossLines() {
    XCTAssertEqual(
      PageMatcher.joinHyphenatedLineBreaks(["it was a some-", "thing new"]),
      ["it was a", "something new"]
    )
  }

  func testNormalizesPunctuationCaseAndAccents() {
    XCTAssertEqual(TextNormalizer.tokenize("“Don’t,” said Zoë — well-known."), ["dont", "said", "zoe", "well", "known"])
  }

  // MARK: - Fixtures

  /// Random words from a 400-word vocabulary: like prose, phrases of 4 words are nearly unique
  private static func makeBook(wordCount: Int, seed: UInt64) -> [String] {
    var state = seed
    func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state >> 33
    }
    let syllables = ["ka", "lo", "mi", "ren", "tu", "sha", "vel", "or", "ix", "bra", "en", "dor", "pa", "qui", "sel", "ta", "um", "zo", "an", "fi"]
    let vocabulary = (0..<400).map { i in syllables[i % 20] + syllables[(i / 20) % 20] + (i % 3 == 0 ? "s" : "") }
    return (0..<wordCount).map { _ in vocabulary[Int(next() % UInt64(vocabulary.count))] }
  }

  private static func transcript(of words: [String]) -> BookTranscript {
    BookTranscript(
      bookUUID: "test",
      duration: Double(words.count) * secondsPerWord,
      model: "test",
      words: words.enumerated().map { index, word in
        TranscriptWord(
          text: word,
          start: Double(index) * secondsPerWord,
          end: Double(index) * secondsPerWord + secondsPerWord * 0.8
        )
      }
    )
  }

  /// Ten words a line, every 9th word misread, the line before last hyphenated
  private static func scannedPage(_ words: [String]) -> [String] {
    let misread = words.enumerated().map { index, word in
      index % 9 == 4 ? String(word.dropLast()) + "rn" : word
    }
    var lines = stride(from: 0, to: misread.count, by: 10).map {
      misread[$0..<min($0 + 10, misread.count)].joined(separator: " ")
    }
    if lines.count >= 3, var last = lines.popLast(), var previous = lines.popLast() {
      let firstWord = last.prefix { $0 != " " }
      if firstWord.count > 3 {
        let cut = firstWord.index(firstWord.startIndex, offsetBy: 2)
        previous += " \(firstWord[..<cut])-"
        last = String(last.dropFirst(2))
      }
      lines += [previous, last]
    }
    return lines
  }
}
