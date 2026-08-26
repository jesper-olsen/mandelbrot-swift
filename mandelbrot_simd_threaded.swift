import Dispatch
import Foundation

// SIMD + threaded variant of mandelbrot.swift, analogous to
// mandelbrot_simd_pthread_v8.c / MandelbrotSimdThreaded.java.
//
// Unlike Java's Vector API, Swift's SIMD support is a stable, first-class
// part of the standard library (since Swift 5.0) - no incubator module, no
// extra compiler/runtime flags. SIMD8<Float> is also a *fixed*-width type
// by design (always 8 lanes), so unlike Java's hardware-adaptive
// SPECIES_PREFERRED, this maps directly onto C's hardcoded 8-wide v8f with
// no "lane width varies by CPU" caveat.
//
// The SIMD kernel computes in float32 rather than the scalar path's
// float64, which means a small fraction of pixels - those right on the
// fractal's boundary, where escape time is chaotically sensitive to input -
// get an iteration count that differs from the double-precision result by
// more than one. Same precision tradeoff the C SIMD kernel's docstring
// documents, not a bug.
//
// Row parallelism is via DispatchQueue.concurrentPerform, same as
// mandelbrot_threaded.swift - see that file for why (no manual thread pool
// or atomic counter needed; writes go through an UnsafeMutableBufferPointer
// since concurrent Array subscript writes aren't a sanctioned pattern).

typealias V8f = SIMD8<Float>
typealias V8i = SIMD8<Int32>

struct Config {
  var width: Int = 100
  var height: Int = 75
  var png: Bool = false
  var ll_x: Double = -1.2
  var ll_y: Double = 0.20
  var ur_x: Double = -1.0
  var ur_y: Double = 0.35
  var max_iter: Int = 255
  var threads: Int = 0  // 0 = let libdispatch decide; 1 = force sequential
}

/// Maps an iteration count to an ASCII character.
func cnt2char(_ value: Int, maxIter: Int) -> Character {
  let symbols = Array("MW2a_. ")
  let idx = Int(Double(value) / Double(maxIter) * Double(symbols.count - 1))
  return symbols[idx]
}

/// Calculates the escape time for a single point in the complex plane
/// (double precision) - used for the scalar remainder columns.
func escapeTime(cr: Double, ci: Double, maxIter: Int) -> Int {
  var zr = 0.0
  var zi = 0.0
  var iter = 0
  while iter < maxIter {
    let zr2 = zr * zr
    let zi2 = zi * zi
    if zr2 + zi2 > 4.0 { break }
    let tmp = zr2 - zi2 + cr
    zi = 2.0 * zr * zi + ci
    zr = tmp
    iter += 1
  }
  return maxIter - iter
}

/// Calculates the escape time for 8 points at once (float32). Every lane
/// keeps iterating - there's no per-lane early exit - and a mask (active)
/// stops lanes from accumulating further iterations once they've escaped,
/// until either every lane has escaped or maxIter is reached. Same approach
/// as escape_time_simd8 in the C SIMD port.
func escapeTimeSimd8(cr: V8f, ci: V8f, maxIter: Int) -> V8i {
  var zr = V8f.zero
  var zi = V8f.zero
  var iters = V8i.zero
  let ones = V8i(repeating: 1)
  let threshold = V8f(repeating: 4.0)
  var active = SIMDMask<SIMD8<Int32>>(repeating: true)

  for _ in 0..<maxIter {
    let zr2 = zr * zr
    let zi2 = zi * zi
    let stillGoing = (zr2 + zi2) .<= threshold
    active = active .& stillGoing
    if !any(active) { break }

    let tmp = zr2 - zi2 + cr
    zi = 2.0 * zr * zi + ci
    zr = tmp

    iters &+= V8i.zero.replacing(with: ones, where: active)
  }

  let maxIterV = V8i(repeating: Int32(maxIter))
  return maxIterV &- iters
}

/// Computes escape times for every row (y = 0..<height, top row first),
/// 8 columns at a time via the SIMD kernel with a scalar remainder for
/// columns that don't fill a full vector. Shared by both output modes -
/// asciiOutput and gpTextOutput print the same rows, just in different
/// order.
///
/// Runs sequentially (no DispatchQueue at all) when config.threads == 1,
/// so you get a true single-thread number rather than whatever a
/// one-iteration-wide concurrentPerform call happens to do - useful for
/// isolating what SIMD alone brings, independent of parallelism.
/// Otherwise runs via concurrentPerform, whose actual worker count isn't
/// user-controllable (GCD decides).
func computeBuffer(config: Config) -> [Int] {
  let fWidth = config.ur_x - config.ll_x
  let fHeight = config.ur_y - config.ll_y
  let lanes = V8f.scalarCount
  var buffer = [Int](repeating: 0, count: config.width * config.height)

  buffer.withUnsafeMutableBufferPointer { buf in
    if config.threads == 1 {
      for y in 0..<config.height {
        let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
        let ci = V8f(repeating: Float(imag))
        let rowOffset = y * config.width
        var x = 0

        while x + lanes <= config.width {
          let cr = V8f(
            Float(config.ll_x + Double(x + 0) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 1) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 2) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 3) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 4) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 5) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 6) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 7) * fWidth / Double(config.width))
          )
          let vals = escapeTimeSimd8(cr: cr, ci: ci, maxIter: config.max_iter)
          for lane in 0..<lanes {
            buf[rowOffset + x + lane] = Int(vals[lane])
          }
          x += lanes
        }

        while x < config.width {
          let real = config.ll_x + Double(x) * fWidth / Double(config.width)
          buf[rowOffset + x] = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
          x += 1
        }
      }
    } else {
      DispatchQueue.concurrentPerform(iterations: config.height) { y in
        let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
        let ci = V8f(repeating: Float(imag))
        let rowOffset = y * config.width
        var x = 0

        while x + lanes <= config.width {
          let cr = V8f(
            Float(config.ll_x + Double(x + 0) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 1) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 2) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 3) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 4) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 5) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 6) * fWidth / Double(config.width)),
            Float(config.ll_x + Double(x + 7) * fWidth / Double(config.width))
          )
          let vals = escapeTimeSimd8(cr: cr, ci: ci, maxIter: config.max_iter)
          for lane in 0..<lanes {
            buf[rowOffset + x + lane] = Int(vals[lane])
          }
          x += lanes
        }

        while x < config.width {
          let real = config.ll_x + Double(x) * fWidth / Double(config.width)
          buf[rowOffset + x] = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
          x += 1
        }
      }
    }
  }
  return buffer
}

/// Renders the Mandelbrot set as ASCII art, computed in parallel across rows.
func asciiOutput(config: Config) {
  let buffer = computeBuffer(config: config)
  for y in 0..<config.height {
    var line = ""
    line.reserveCapacity(config.width)
    let rowOffset = y * config.width
    for x in 0..<config.width {
      line.append(cnt2char(buffer[rowOffset + x], maxIter: config.max_iter))
    }
    print(line)
  }
}

/// Generates text output suitable for gnuplot, computed in parallel across rows.
func gpTextOutput(config: Config) {
  let buffer = computeBuffer(config: config)
  let stdout = FileHandle.standardOutput
  // gnuplot's 'matrix with image' treats the first line as the bottom row,
  // so print the same rows asciiOutput computes, just reversed.
  for y in (0..<config.height).reversed() {
    var rowString = ""
    rowString.reserveCapacity(config.width * 6)
    let rowOffset = y * config.width
    for x in 0..<config.width {
      if x > 0 { rowString += ", " }
      rowString += String(buffer[rowOffset + x])
    }
    rowString += "\n"
    if let data = rowString.data(using: .utf8) {
      stdout.write(data)
    }
  }
}

/// Parses a single "key=value" command-line argument.
func parseArg(_ arg: String, config: inout Config) {
  let parts = arg.split(separator: "=", maxSplits: 1)
  guard parts.count == 2 else { return }
  let key = parts[0]
  let value = String(parts[1])
  switch key {
  case "width": config.width = Int(value) ?? config.width
  case "height": config.height = Int(value) ?? config.height
  case "png": config.png = (Int(value) ?? 0) != 0
  case "ll_x": config.ll_x = Double(value) ?? config.ll_x
  case "ll_y": config.ll_y = Double(value) ?? config.ll_y
  case "ur_x": config.ur_x = Double(value) ?? config.ur_x
  case "ur_y": config.ur_y = Double(value) ?? config.ur_y
  case "max_iter": config.max_iter = Int(value) ?? config.max_iter
  case "threads": config.threads = Int(value) ?? config.threads
  default:
    fputs("Warning: Unknown parameter '\(key)'\n", stderr)
  }
}

var config = Config()

for arg in CommandLine.arguments.dropFirst() {
  parseArg(arg, config: &config)
}

if config.png {
  gpTextOutput(config: config)
} else {
  asciiOutput(config: config)
}
