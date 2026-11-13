import CoreGraphics

/// Where read-along should put the scroll offset so the spoken word stays in view.
///
/// The reader used to publish the word's y as `blockMinY + fraction * geometryHeight`, with `geometryHeight` taken
/// from a `GeometryReader` in the block's background. Inside a `ScrollView` that reader is offered the scroll view's
/// flexible height, so it reports a frame that starts at the top of the article and is as tall as the article. Any
/// word past the start of a block then has a y at the bottom, and the scroller clamps there and stays there.
///
/// The y now comes from the block's anchor bounds (its real frame). A frame that still covers the whole article from
/// the top is rejected, so a bad measurement does not move the page.
enum ReadAlongScroll {
    /// Leave the page still while the word sits in this band of the viewport.
    static let bandTop: CGFloat = 0.12
    static let bandBottom: CGFloat = 0.70
    /// Where a word that has left the band is placed.
    static let settle: CGFloat = 0.28

    /// Y of the spoken word from the top of the article, or nil when the frame can't be trusted.
    static func wordY(blockMinY: CGFloat, blockHeight: CGFloat, wordFraction: CGFloat, contentHeight: CGFloat) -> CGFloat? {
        guard blockMinY.isFinite, blockHeight.isFinite, blockHeight > 0, wordFraction.isFinite, contentHeight.isFinite else { return nil }
        // The old background geometry: one frame for the whole article, origin at the top. Using it as the block
        // sends every later word to the bottom. A real block is shorter, or it doesn't start at the top.
        if contentHeight > 0, blockMinY <= 8, blockHeight >= contentHeight * 0.9 { return nil }
        let fraction = min(max(wordFraction, 0), 1)
        let y = blockMinY + fraction * blockHeight
        guard y.isFinite else { return nil }
        return y
    }

    /// Content offset that puts `wordY` at `settle` in the viewport, or nil when the word is already in the band
    /// (unless `force`) or the numbers aren't usable. Never returns the bottom of the article unless `wordY` is
    /// actually down there.
    static func targetOffset(wordY: CGFloat, viewport: CGFloat, contentHeight: CGFloat, currentOffset: CGFloat, force: Bool) -> CGFloat? {
        guard wordY.isFinite, viewport.isFinite, viewport > 0, contentHeight.isFinite, contentHeight > 0, currentOffset.isFinite else { return nil }
        let maxOffset = max(0, contentHeight - viewport)
        guard maxOffset > 0 else { return force ? 0 : nil }
        let inView = wordY - currentOffset
        if !force, inView >= viewport * bandTop, inView <= viewport * bandBottom { return nil }
        return min(max(wordY - viewport * settle, 0), maxOffset)
    }

    /// The offset to apply for this block frame, combining `wordY` and `targetOffset`.
    static func followTarget(blockMinY: CGFloat, blockHeight: CGFloat, wordFraction: CGFloat, contentHeight: CGFloat,
                              viewport: CGFloat, currentOffset: CGFloat, force: Bool) -> CGFloat? {
        guard let y = wordY(blockMinY: blockMinY, blockHeight: blockHeight, wordFraction: wordFraction, contentHeight: contentHeight) else { return nil }
        return targetOffset(wordY: y, viewport: viewport, contentHeight: contentHeight, currentOffset: currentOffset, force: force)
    }
}
