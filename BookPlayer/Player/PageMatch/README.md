# Page Match

Scan a page of the printed book (or a photo of an e-reader screen) and play the audiobook from that spot. Spotify's Page Match works from publisher text; BookPlayer has only the audio, so it **transcribes each book once, on device**, and matches scanned pages against that transcript. Because it matches the words themselves, not page numbers, it works with any edition.

| File | Role |
|---|---|
| `BookTranscript.swift` | Transcript model (word + start/end in book time), storage, text normalisation |
| `BookTranscriber.swift` | WhisperKit transcription in 10-minute slices, so memory stays flat on long books |
| `PageScanner.swift` | Vision OCR → body lines; drops page numbers, running heads and footers, and splits two-page spreads |
| `PageMatcher.swift` | Matching: page → time (plus a time per line), and time → passage |
| `PageMatchViewModel.swift` / `PageMatchView.swift` | The sheet opened from the player's More menu |

## Matching

1. **Voting.** Each 4-word phrase on the page that also appears in the transcript votes for an offset. The densest cluster of votes wins, and rare phrases weigh more. If too few 4-word phrases match, it falls back to 3-word phrases.
2. **Alignment.** The page is aligned word by word, allowing near-misses (edit distance 1–2), against about 500 transcript words around the winner. This absorbs OCR and Whisper errors and gives each line a start time.
3. **Gate.** `isReliable` requires at least 60% of words aligned, a vote confidence of 0.05 or more, and no strong second candidate.

These thresholds came from a simulation on two Gutenberg novels (*Emma*, *Moby Dick*), with synthetic Whisper errors (6% wrong words, 3% dropped, 2% extra) and OCR errors (up to 12%):
- Full pages landed within 3 s every time, with no wrong jumps.
- 15-word snippets landed within 3 s 99% of the time.
- Pages from another Austen novel were wrongly accepted 1 time in 300, all of them 15-word snippets.

Real recordings and photos will be messier, so re-check the thresholds on real books.

## Known gaps / next steps

- Transcription runs in the foreground with the screen kept awake. Moving it to a `BGContinuedProcessingTask` (like `UploadContinuationController`) would let it run in the background.
- Transcription speed on real devices hasn't been measured yet.
- New strings are in English in every locale until they're translated.
- Streamed books, and books not downloaded to this device, aren't supported.
- Without the ebook, the audio → page direction shows the sentence being read rather than a page number.
