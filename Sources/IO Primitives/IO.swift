//
//  IO.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 24/12/2025.
//

/// Namespace for async I/O primitives.
///
/// Provides:
/// - `IO.Executor<Resource>`: Actor-based handle registry with bounded queue
/// - `IO.Blocking.Lane`: Protocol witness for blocking I/O strategies
/// - `IO.Blocking.Threads`: Dedicated OS thread pool implementation
public enum IO {}
