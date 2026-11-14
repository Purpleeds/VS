import Foundation

/// Lines up two word sequences (e.g. what was heard and what it was corrected to, or two repeats of a chorus).
///
/// Anchors are the best in-order pairing of equal or similar words (`LyricListenMatcher.similarity`, dynamic
/// programming). Between two anchors, stretches of the same length are paired word for word (substitutions); every
/// stretch where the two sides differ is also reported as an edit block ("beyond say" → "Beyoncé").
public enum WordAlignment {
    public enum Kind: Sendable, Equatable {
        case same
        case similar
        case substituted
    }

    public struct Pair: Sendable, Equatable {
        public var a: Int
        public var b: Int
        public var kind: Kind

        public init(a: Int, b: Int, kind: Kind) {
            self.a = a
            self.b = b
            self.kind = kind
        }
    }

    /// A stretch where the sequences differ: `a[aRange]` stands where `b[bRange]` does (one side may be empty).
    /// Stretches of equal length are split word for word.
    public struct Block: Sendable, Equatable {
        public var aRange: Range<Int>
        public var bRange: Range<Int>

        public init(aRange: Range<Int>, bRange: Range<Int>) {
            self.aRange = aRange
            self.bRange = bRange
        }
    }

    public struct Result: Sendable, Equatable {
        public var pairs: [Pair]
        public var blocks: [Block]
    }

    /// Longest sequences aligned (longer inputs are cut, to bound the work).
    public static let maximumWords = 2_000

    /// `a` and `b` are words (any spelling); they are compared by `LyricListenMatcher.key`.
    public static func align(_ a: [String], _ b: [String]) -> Result {
        let x = Array(a.prefix(maximumWords)).map(LyricListenMatcher.key)
        let y = Array(b.prefix(maximumWords)).map(LyricListenMatcher.key)
        return align(keys: x, sounds: x.map(LyricListenMatcher.phonetic), against: y, againstSounds: y.map(LyricListenMatcher.phonetic))
    }

    /// Same, with keys and sound keys already worked out (the word predictor aligns many lines).
    static func align(keys x: [String], sounds xs: [String?], against y: [String], againstSounds ys: [String?]) -> Result {
        let rows = x.count, cols = y.count
        var anchors: [Pair] = []
        if rows > 0, cols > 0 {
            let width = cols + 1
            var score = [Int32](repeating: 0, count: (rows + 1) * width)
            for i in 1...rows {
                for j in 1...cols {
                    let s = LyricListenMatcher.similarity(x[i - 1], y[j - 1], xs[i - 1], ys[j - 1])
                    var best = max(score[(i - 1) * width + j], score[i * width + j - 1])
                    if s > 0 { best = max(best, score[(i - 1) * width + j - 1] + Int32(s)) }
                    score[i * width + j] = best
                }
            }
            var i = rows, j = cols
            while i > 0, j > 0 {
                let s = LyricListenMatcher.similarity(x[i - 1], y[j - 1], xs[i - 1], ys[j - 1])
                if s > 0, score[i * width + j] == score[(i - 1) * width + j - 1] + Int32(s) {
                    anchors.append(Pair(a: i - 1, b: j - 1, kind: x[i - 1] == y[j - 1] ? .same : .similar))
                    i -= 1
                    j -= 1
                } else if score[i * width + j] == score[(i - 1) * width + j - 1] {
                    // Skipping both costs nothing: step diagonally, so repeats of a line pair up position by position.
                    i -= 1
                    j -= 1
                } else if score[(i - 1) * width + j] >= score[i * width + j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            anchors.reverse()
        }
        // Pairs: every anchor, plus word-for-word pairs across equal-length stretches between anchors.
        var pairs: [Pair] = []
        var lastA = -1, lastB = -1
        for anchor in anchors + [Pair(a: rows, b: cols, kind: .same)] {
            let gapA = (lastA + 1)..<anchor.a, gapB = (lastB + 1)..<anchor.b
            if !gapA.isEmpty, gapA.count == gapB.count {
                for offset in 0..<gapA.count {
                    pairs.append(Pair(a: gapA.lowerBound + offset, b: gapB.lowerBound + offset, kind: .substituted))
                }
            }
            if anchor.a < rows { pairs.append(anchor) }
            lastA = anchor.a
            lastB = anchor.b
        }
        // Blocks: what differs between exact matches (a near miss belongs with the words around it).
        var blocks: [Block] = []
        lastA = -1
        lastB = -1
        for anchor in anchors.filter({ $0.kind == .same }) + [Pair(a: rows, b: cols, kind: .same)] {
            let gapA = (lastA + 1)..<anchor.a, gapB = (lastB + 1)..<anchor.b
            if gapA.count == gapB.count {
                for offset in 0..<gapA.count where x[gapA.lowerBound + offset] != y[gapB.lowerBound + offset] {
                    blocks.append(Block(aRange: (gapA.lowerBound + offset)..<(gapA.lowerBound + offset + 1),
                                        bRange: (gapB.lowerBound + offset)..<(gapB.lowerBound + offset + 1)))
                }
            } else {
                blocks.append(Block(aRange: gapA, bRange: gapB))
            }
            lastA = anchor.a
            lastB = anchor.b
        }
        return Result(pairs: pairs, blocks: blocks)
    }
}
