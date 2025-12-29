# swift-io

![Development Status](https://img.shields.io/badge/status-active--development-blue.svg)

A high-performance async I/O executor for Swift. Isolates blocking syscalls from Swift's cooperative thread pool with dedicated worker threads, bounded queues, and deterministic shutdown semantics.

## Key Features

- **Dedicated thread pool** - Blocking I/O never starves Swift's cooperative executor
- **Context-based completion** - 18x faster than dictionary lookup (83ns vs 1.5µs)
- **Transition-based signaling** - Minimal kernel overhead, 30% faster concurrent throughput
- **Move-only resources** - Generic over `~Copyable` with type-safe slot transport
- **Typed throws** - `IO.Error<E>` preserves your operation's error type
- **Swift 6 strict concurrency** - Full `Sendable` compliance, zero data races

## Performance

Benchmarks comparing swift-io against SwiftNIO's `NIOThreadPool` (release mode, arm64):

### Throughput

| Benchmark | swift-io | NIOThreadPool | Difference |
|-----------|----------|---------------|------------|
| Sequential (1000 ops) | 4.42ms | 7.39ms | **40% faster** |
| Concurrent (1000 ops) | 1.88ms | 1.71ms | ~10% slower |

### Overhead (per-operation)

| Benchmark | swift-io | NIOThreadPool | Difference |
|-----------|----------|---------------|------------|
| Thread dispatch | 4.08µs | 7.67µs | **47% faster** |
| Success path | 4.08µs | 7.46µs | **45% faster** |
| Failure path | 4.50µs | 10.88µs | **59% faster** |
| Queue admission | 4.04µs | 7.88µs | **49% faster** |

### Contention

| Scenario | swift-io | NIOThreadPool |
|----------|----------|---------------|
| Moderate (10:1) | 232µs | 199µs |
| High (100:1) | 784µs | 913µs |
| Extreme (1000:1) | 3.85ms | 2.93ms |

### Design Wins

| Component | swift-io | Alternative | Speedup |
|-----------|----------|-------------|---------|
| Context-based completion | 83ns | Dictionary lookup: 1.50µs | **18x** |
| Concurrent completion | 44µs | Dictionary-based: 78µs | **1.8x** |

## Why swift-io?

Swift's cooperative thread pool is designed for quick, non-blocking work. When you mix in blocking syscalls:

| Problem | Cooperative Pool | swift-io |
|---------|------------------|----------|
| **Blocking syscalls** | Starves cooperative threads | Dedicated threads isolate blocking work |
| **Waiter management** | Manual continuation handling | Bounded FIFO queues with backpressure |
| **Resource cleanup** | Manual, error-prone | Deterministic teardown strategies |
| **Cancellation** | Inconsistent semantics | Well-defined: before/after acceptance |
| **Move-only resources** | No native support | Generic over `~Copyable` with slot pattern |
| **Error handling** | Untyped throws | Typed throws with `IO.Error<E>` |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/coenttb/swift-io.git", from: "0.1.0")
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "IO", package: "swift-io"),
    ]
)
```

**Requirements:** Swift 6.0+, macOS 14.0+ / iOS 17.0+ / Linux / Windows

## Quick Start

```swift
import IO

// Create a pool for your resource type
let pool = IO.Executor.Pool<MyResource>()

// Register a resource
let id = try await pool.register {
    try MyResource.open(path)
}

// Execute with exclusive access
let result = try await pool.transaction(id) { resource in
    try resource.read()
}

// Cleanup
try await pool.destroy(id)
await pool.shutdown()
```

### Running Blocking Operations

```swift
// Run blocking work on dedicated threads
let data = try await pool.run {
    try blockingSyscall()
}
```

### Transaction-Based Access

```swift
// Exclusive access to a resource
try await pool.transaction(handleID) { resource in
    try resource.write(data)
    return try resource.read()
}
```

### Error Handling

```swift
do {
    let result = try await pool.run {
        try myOperation()  // throws MyError
    }
} catch .operation(let error) {
    // error is MyError (typed!)
} catch .executor(.shutdownInProgress) {
    // Pool is shutting down
} catch .cancelled {
    // Task was cancelled
}
```

## Architecture

```
┌─────────────────────────────────────────────┐
│                    IO                        │  ← Pool, Handle.ID, Error
├─────────────────────────────────────────────┤
│              IO Blocking                     │  ← Lane abstraction
├─────────────────────────────────────────────┤
│           IO Blocking Threads                │  ← Thread pool + signal optimization
├─────────────────────────────────────────────┤
│              IO Primitives                   │  ← Core types, platform abstraction
└─────────────────────────────────────────────┘
```

### Key Types

| Type | Purpose |
|------|---------|
| `IO.Executor.Pool<Resource>` | Actor-based resource pool with transaction access |
| `IO.Handle.ID` | Scoped identifier for registered resources |
| `IO.Blocking.Lane` | Execution backend (`.threads()` or `.sharded()`) |
| `IO.Error<E>` | Typed error wrapper preserving operation errors |

### Execution Model

```
Swift Task                    Lane (Thread Pool)
    │                              │
    ├─── run(operation) ──────────►│
    │    (suspends)                │
    │                              ├─── execute on worker thread
    │                              │
    │◄── resume with result ───────┤
    │    (context-based, no lookup)│
```

## Design Details

### Signal Optimization

Workers use transition-based signaling to minimize kernel overhead:

- **Sleepers tracking** - Only signal when workers are actually waiting
- **Empty→non-empty transitions** - Signal once per batch, not per job
- **Drain loop** - Process up to 16 jobs per wake cycle

This eliminates ~90% of spurious `pthread_cond_signal` calls.

### Context-Based Completion

Jobs carry their completion context, eliminating dictionary lookups:

```swift
// Traditional: O(1) amortized but with hash overhead
completions[ticket] = result  // store
let result = completions.removeValue(forKey: ticket)  // lookup

// swift-io: Direct pointer, zero lookup
job.context.tryComplete(with: result)  // 83ns
```

### Guarantees

**What swift-io guarantees:**
- Exactly-once continuation resumption
- FIFO fairness (best effort under contention)
- Bounded memory via capacity-limited queues
- Deterministic shutdown with in-flight completion
- Cancellation safety

**What swift-io does NOT guarantee:**
- Syscall interruption after acceptance
- Exact FIFO under heavy contention
- Cross-process coordination

## Configuration

```swift
// Custom thread pool
let pool = IO.Executor.Pool<MyResource>(
    lane: .threads(.init(count: 4, queueLimit: 128)),
    handleWaitersLimit: 32
)

// Sharded lane for reduced contention
let pool = IO.Executor.Pool<MyResource>(
    lane: .sharded(count: 4)
)

// Custom teardown
let pool = IO.Executor.Pool<FileHandle>(
    teardown: .run { handle in
        try? handle.close()
    }
)
```

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | Full support |
| iOS | Full support |
| Linux | Full support |
| Windows | Full support |

## Related Packages

- [swift-file-system](https://github.com/coenttb/swift-file-system) - File system operations built on swift-io
- [swift-time-standard](https://github.com/swift-standards/swift-time-standard) - Time types for deadlines

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.
