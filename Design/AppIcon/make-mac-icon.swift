import AppKit
let src = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let S = 1024, tile: CGFloat = 824, origin: CGFloat = 100
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// superellipse (n=5) squircle
let path = CGMutablePath(); let n: CGFloat = 5; let r = tile/2; let c = CGPoint(x: origin + r, y: origin + r)
for i in 0...720 {
  let t = CGFloat(i) / 720 * 2 * .pi
  let ct = cos(t), st = sin(t)
  let x = c.x + r * copysign(pow(abs(ct), 2/n), ct)
  let y = c.y + r * copysign(pow(abs(st), 2/n), st)
  i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
}
path.closeSubpath()
// shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
// artwork clipped
ctx.saveGState(); ctx.addPath(path); ctx.clip()
var rect = CGRect(x: 0, y: 0, width: S, height: S)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: origin, y: origin, width: tile, height: tile))
ctx.restoreGState()
// hairline edge highlight
ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(2); ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
