//
//  PageScanner.swift
//  BookPlayer
//
//  Created by Shubham Mishra on 14/11/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//
//  Photo of a page → clean lines of body text, using Apple's on-device Vision OCR.
//  Works on paper books and on photos of an e-reader / Kindle screen.
//

import CoreGraphics
import ImageIO
import Vision

public enum PageScanner {
  public enum ScanError: Error { case noText }

  /// Returns the page's body text, one string per printed line, top to bottom,
  /// with page numbers and running heads removed.
  public static func lines(
    in image: CGImage,
    orientation: CGImagePropertyOrientation = .up,
    languages: [String] = ["en-US"]
  ) async throws -> [String] {
    let observations = try await recognize(image, orientation: orientation, languages: languages)
    let lines = bodyLines(from: observations)
    guard !lines.isEmpty else { throw ScanError.noText }
    return lines
  }

  // MARK: OCR

  private static func recognize(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation,
    languages: [String]
  ) async throws -> [VNRecognizedTextObservation] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        // Language correction fixes most "rn"→"m" style errors; the matcher tolerates the rest.
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01   // ignore specks / text on the facing page edge
        do {
          try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
          continuation.resume(returning: request.results ?? [])
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: Clean-up

  private struct Line {
    let text: String
    let box: CGRect   // Vision coordinates: normalised, origin bottom-left
  }

  static func bodyLines(from observations: [VNRecognizedTextObservation]) -> [String] {
    var lines: [Line] = observations.compactMap { observation in
      guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
      let text = candidate.string.trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : Line(text: text, box: observation.boundingBox)
    }
    // Page numbers anywhere ("143", "xii").
    lines.removeAll { isPageNumber($0.text) }

    // A two-page spread: read the left page fully, then the right one.
    let left = lines.filter { $0.box.maxX < 0.52 }
    let right = lines.filter { $0.box.minX > 0.48 }
    let isSpread = Double(left.count) > Double(lines.count) * 0.3 && Double(right.count) > Double(lines.count) * 0.3
    let pages = isSpread ? [left, right] : [lines]

    // Top-to-bottom within each page (Vision's y grows upwards).
    return pages.flatMap { page in
      stripHeaderAndFooter(page.sorted { $0.box.midY > $1.box.midY }).map(\.text)
    }
  }

  /// Running head / footer: a short line set apart from the body by a big gap.
  private static func stripHeaderAndFooter(_ sortedLines: [Line]) -> [Line] {
    var lines = sortedLines
    if lines.count >= 4 {
      let gaps = zip(lines, lines.dropFirst()).map { $0.box.minY - $1.box.maxY }
      let typicalGap = gaps.sorted()[gaps.count / 2]
      let isShort: (Line) -> Bool = { $0.text.split(separator: " ").count <= 6 }
      if isShort(lines[lines.count - 1]), gaps[gaps.count - 1] > max(typicalGap * 2.5, 0.02) {
        lines.removeLast()
      }
      if isShort(lines[0]), gaps[0] > max(typicalGap * 2.5, 0.02) {
        lines.removeFirst()
      }
    }
    return lines
  }

  private static func isPageNumber(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    if !t.isEmpty, t.allSatisfy(\.isNumber) { return true }
    let roman = Set("ivxlcdm")
    return t.count <= 6 && !t.isEmpty && t.lowercased().allSatisfy { roman.contains($0) }
  }
}
