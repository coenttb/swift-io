//
//  IO.Blocking.Lane.Count.swift
//  swift-io
//

public import Kernel
public import Dimension

extension IO.Blocking.Lane {
    /// Type-safe count of lanes.
    public typealias Count = Tagged<IO.Blocking.Lane, Int>
}

extension IO.Blocking.Lane.Count {
    /// Creates a lane count from a processor count.
    @inlinable
    public init(_ processorCount: Kernel.System.Processor.Count) {
        self.init(Int(processorCount))
    }
}

extension Int {
    /// Creates an Int from a lane count.
    @inlinable
    public init(_ count: IO.Blocking.Lane.Count) {
        self = count.rawValue
    }
}
