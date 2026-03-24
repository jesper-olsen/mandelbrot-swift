import Foundation

struct Config {
    var width: Int = 100
    var height: Int = 75
    var png: Bool = false
    var ll_x: Double = -1.2
    var ll_y: Double = 0.20
    var ur_x: Double = -1.0
    var ur_y: Double = 0.35
    var max_iter: Int = 255
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

/// Renders the Mandelbrot set as ASCII art.
func asciiOutput(config: Config) {
    let fWidth = config.ur_x - config.ll_x
    let fHeight = config.ur_y - config.ll_y
    
    for y in 0..<config.height {
        var line = ""
        for x in 0..<config.width {
            let real = config.ll_x + Double(x) * fWidth / Double(config.width)
            let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
            let iter = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
            line.append(cnt2char(iter, maxIter: config.max_iter))
        }
        print(line)
    }
}

/// Generates text output suitable for gnuplot.
/// Uses a buffered approach similar to the C implementation for speed.
func gpTextOutput(config: Config) {
    let fWidth = config.ur_x - config.ll_x
    let fHeight = config.ur_y - config.ll_y
    let stdout = FileHandle.standardOutput

    for y in (1...config.height).reversed() {
        var rowString = ""
        rowString.reserveCapacity(config.width * 6) 
        
        for x in 0..<config.width {
            let real = config.ll_x + Double(x) * fWidth / Double(config.width)
            let imag = config.ur_y - Double(y) * fHeight / Double(config.height)
            let iter = escapeTime(cr: real, ci: imag, maxIter: config.max_iter)
            
            if x > 0 { rowString += ", " }
            rowString += String(iter)
        }
        rowString += "\n"
        
        if let data = rowString.data(using: .utf8) {
            stdout.write(data)
        }
    }
}

var config = Config()

// Parse command line arguments: key=value
for arg in CommandLine.arguments.dropFirst() {
    let parts = arg.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else { continue }
    
    let key = parts[0]
    let value = String(parts[1])
    
    switch key {
    case "width":    config.width = Int(value) ?? config.width
    case "height":   config.height = Int(value) ?? config.height
    case "png":      config.png = (Int(value) ?? 0) != 0
    case "ll_x":     config.ll_x = Double(value) ?? config.ll_x
    case "ll_y":     config.ll_y = Double(value) ?? config.ll_y
    case "ur_x":     config.ur_x = Double(value) ?? config.ur_x
    case "ur_y":     config.ur_y = Double(value) ?? config.ur_y
    case "max_iter": config.max_iter = Int(value) ?? config.max_iter
    default:
        fputs("Warning: Unknown parameter '\(key)'\n", stderr)
    }
}

if config.png {
    gpTextOutput(config: config)
} else {
    asciiOutput(config: config)
}
