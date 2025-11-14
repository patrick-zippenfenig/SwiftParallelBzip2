import SwiftParallelBzip2
import NIOFileSystem
import Foundation
import ArgumentParser

@main
struct Command: AsyncParsableCommand {
    @Flag(name: .shortAndLong, help: "Overwrite existing file")
    var force = false
    
    @Flag(name: .shortAndLong, help: "Print debug info")
    var verbose = false
    
    @Argument(help: "Input file path")
    var file: String

    mutating func run() async throws {
        let infile = file
        let outfile = file.replacingOccurrences(of: ".bz2", with: "")
        let newFileOptions: OpenOptions.NewFile? = force ? .init() : nil
        try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(infile)) { readFn in
            try await FileSystem.shared.withFileHandle(forWritingAt: FilePath(outfile), options: OpenOptions.Write(existingFile: .truncate, newFile: newFileOptions)) { writeFn in
                let time = DispatchTime.now()
                try await writeFn.withBufferedWriter { writer in
                    /// Buffer up tp 4 chunks of data from disk
                    let bufferedReader = readFn.readChunks(chunkLength: .kibibytes(128))
                    for try await chunk in bufferedReader.decodeBzip2(nConcurrent: 4) {
                        try await writer.write(contentsOf: chunk)
                    }
                }
                if verbose {
                    print(time.timeElapsedPretty())
                }
            }
        }
    }
}

extension DispatchTime {
    /// Nicely format elapsed time
    func timeElapsedPretty() -> String {
        let seconds = Double((DispatchTime.now().uptimeNanoseconds - uptimeNanoseconds)) / 1_000_000_000
        return seconds.asSecondsPrettyPrint
    }
}
extension Double {
    var asSecondsPrettyPrint: String {
        let milliseconds = self * 1000
        let seconds = self
        let minutes = self / 60
        let hours = self / 3600
        if milliseconds < 5 {
            return "\(milliseconds.round(digits: 2))ms"
        }
        if milliseconds < 20 {
            return "\(milliseconds.round(digits: 1))ms"
        }
        if milliseconds < 800 {
            return "\(Int(milliseconds.round(digits: 0)))ms"
        }
        if milliseconds < 5_000 {
            return "\(seconds.round(digits: 2))s"
        }
        if milliseconds < 20_000 {
            return "\(seconds.round(digits: 1))s"
        }
        if milliseconds < 180_000 {
            return "\(Int(seconds.round(digits: 0)))s"
        }
        if milliseconds < 1000 * 60 * 90 {
            return "\(Int(minutes.round(digits: 0)))m"
        }
        return "\(Int(hours).zeroPadded(len: 2)):\((Int(minutes) % 60).zeroPadded(len: 2))"
    }
    
    func round(digits: Int) -> Double {
        let mut = Foundation.pow(10, Double(digits))
        return (self * mut).rounded() / mut
    }
}

extension Int {
    /// Integer division, but round up instead of floor
    @inlinable func divideRoundedUp(divisor: Int) -> Int {
        return (self + divisor - 1) / divisor
    }
    
    func zeroPadded(len: Int) -> String {
        return String(format: "%0\(len)d", self)
    }
}
