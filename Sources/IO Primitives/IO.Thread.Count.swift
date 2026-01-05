//
//  IO.Thread.Count.swift
//  swift-io
//

public import Kernel
public import Dimension

extension IO.Thread {
    /// Type-safe count of threads.
    public typealias Count = Tagged<IO.Thread, Int>
}

extension IO.Thread.Count {
    /// Creates a thread count from a processor count.
    @inlinable
    public init(_ processorCount: Kernel.System.Processor.Count) {
        self.init(Int(processorCount))
    }
}

extension Int {
    /// Creates an Int from a thread count.
    @inlinable
    public init(_ count: IO.Thread.Count) {
        self = count._rawValue
    }
}
