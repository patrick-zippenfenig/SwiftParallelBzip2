import SwiftParallelBzip2
import NIOFileSystem

func main() async throws {
    let infile = "/Volumes/2TB_USB/ope_s1_ifs-seas_od_mmsf_fc_20251101T000000Z_202511_m01.bz2"
    let outfile = "/Volumes/2TB_USB/decompressed"
    try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(infile)) { readFn in
        try await FileSystem.shared.withFileHandle(forWritingAt: FilePath(outfile), options: OpenOptions.Write(existingFile: .truncate, newFile: .some(.init()))) { writeFn in
            try await writeFn.withBufferedWriter { writer in
                for try await chunk in try await readFn.readChunks(chunkLength: .kibibytes(128)).decodeBzip2(bufferPolicy: .bounded(4)) {
                    try await writer.write(contentsOf: chunk)
                }
            }
        }
    }
}

try await main()
