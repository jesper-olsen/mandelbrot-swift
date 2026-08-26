import Dispatch
import Foundation

// Threaded variant of mandelbrot.swift: computes escape times for all rows
// in parallel via DispatchQueue.concurrentPerform (GCD), the idiomatic
// Swift/Apple-platform tool for an embarrassingly-parallel loop over
// independent iterations writing into a shared preallocated buffer.
//
// Unlike the C/Java pthread ports in this comparison, this doesn't manage
// its own fixed-size thread pool or an explicit work-claiming counter -
// libdispatch's global concurrent queue owns that decision. Row writes go
// through an UnsafeMutableBufferPointer (via withUnsafeMutableBufferPointer)
// rather than plain Array subscripting, since concurrent writes to a
// Swift Array's normal subscript from multiple threads - even to disjoint
// indices - aren't a sanctioned pattern; writing through the unsafe buffer
// pointer is the standard, documented way to do this safely.
//
// asciiOutput and gpTextOutput now share one buffer computation (computeBuffer)
// since they iterate the same row range - just printed in opposite order.

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

/// Calculates the escape time for a point in the complex plane.
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

/// Computes escape times for every row (y = 0..<height, top row first),
/// into a flat width*height buffer. Shared by both output modes -
/// asciiOutput and gpTextOutput print the same rows, just in different
/// order.
///
/// Runs sequentially (no DispatchQueue at all) when config.threads == 1,
/// for a true single-thread baseline - concurrentPerform's actual worker
/// count isn't user-controllable (GCD decides).
func computeBuffer(config: Config) -> [Int] {
  let fWidth = config.ur_x - config.ll_x
  let fHeight = config.ur_y - config.ll_y
  var buffer = [Int](repeating: 0, count: config.width * config.height)
  buffer.withUnsafeMutableBufferPointer { buf in
    if config.threads == 1 {
      for y in 0..<config.height {
        let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
        let rowOffset = y * config.width
        for x in 0..<config.width {
          let real = config.ll_x + Double(x) * fWidth / Double(config.width)
          buf[rowOffset + x] = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
        }
      }
    } else {
      DispatchQueue.concurrentPerform(iterations: config.height) { y in
        let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
        let rowOffset = y * config.width
        for x in 0..<config.width {
          let real = config.ll_x + Double(x) * fWidth / Double(config.width)
          buf[rowOffset + x] = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
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
