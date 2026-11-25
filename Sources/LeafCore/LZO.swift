import Foundation

/// Bounds-checked LZO1X (original stream format), used by older MDict archives.
/// Instruction layout: https://www.kernel.org/doc/html/latest/staging/lzo.html
/// This decoder intentionally rejects LZO-RLE, which is not the MDX compression format.
enum LZO {
    static func decompress(_ input: Data, expected: Int) throws -> Data {
        guard expected >= 0, expected <= 128 * 1024 * 1024 else { throw LeafError.invalid("LZO 数据块过大。") }
        var reader = ByteReader(data: input), output = Data(); output.reserveCapacity(expected)
        func invalid() -> LeafError { .invalid("LZO 数据损坏或使用不支持的流版本。") }
        func next() throws -> Int { try reader.int(1) }
        func literals(_ length: Int) throws {
            guard length >= 0, length <= expected-output.count else { throw invalid() }
            output.append(try reader.bytes(length))
        }
        func variable(_ initial: Int, _ mask: Int) throws -> Int {
            if initial != 0 { return initial }
            var length = mask
            while true {
                let byte = try next()
                if byte != 0 { length += byte; break }
                length += 255
                guard length <= expected else { throw invalid() }
            }
            return length
        }
        var state = 0
        guard reader.remaining >= 3 else { throw invalid() }
        if input[0] > 17 {
            let count = try next()-17
            try literals(count); state = count < 4 ? count : 4
        }
        while reader.remaining > 0 {
            let instruction = try next()
            var count: Int, distance: Int, trailing: Int
            if instruction < 16 {
                if state == 0 {
                    count = try variable(instruction,15)+3
                    try literals(count); state=4; continue
                }
                distance = (try next())*4+(instruction>>2)+(state==4 ? 2049 : 1)
                count = state==4 ? 3 : 2; trailing=instruction&3
            } else if instruction < 32 {
                count = try variable(instruction&7,7)+2
                let operand = try reader.int(2,little:true)
                distance = 16384+((instruction&8)<<11)+(operand>>2); trailing=operand&3
                if distance==16384 {
                    guard count==3, trailing==0, reader.remaining==0, output.count==expected else { throw invalid() }
                    return output
                }
            } else if instruction < 64 {
                count = try variable(instruction&31,31)+2
                let operand = try reader.int(2,little:true)
                distance=(operand>>2)+1; trailing=operand&3
            } else {
                count=(instruction>>5)+1
                distance=(try next())*8+((instruction>>2)&7)+1; trailing=instruction&3
            }
            guard distance > 0, distance <= output.count, count <= expected-output.count else { throw invalid() }
            // Overlapping references deliberately read bytes appended during this instruction.
            for _ in 0..<count { output.append(output[output.count-distance]) }
            try literals(trailing); state=trailing
        }
        throw invalid()
    }
}
