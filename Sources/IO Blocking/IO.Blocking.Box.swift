//
//  IO.Blocking.Box.swift
//  swift-io
//
//  Type-erased boxing for lane results.
//  Now implemented via Kernel.Handoff.Box.
//

extension IO.Blocking {
    /// Type-erased boxing for lane results.
    ///
    /// This is a typealias to `Kernel.Handoff.Box`, providing a consistent API
    /// for the IO module while leveraging the kernel-level implementation.
    public typealias Box = Kernel.Handoff.Box
}
