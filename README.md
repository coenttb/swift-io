# swift-io

![Development Status](https://img.shields.io/badge/status-active--development-blue.svg)

Actor-based async I/O executor for Swift with bounded waiter queues, move-only resource handling, and deterministic shutdown. Generic over `~Copyable` resources. Swift 6 strict concurrency with typed throws throughout.

## Table of Contents

- [Why swift-io?](#why-swift-io)
- [Overview](#overview)
- [Design Principles](#design-principles)
- [Design Guarantees](#design-guarantees)
- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Architecture](#architecture)
- [Platform Support](#platform-support)
- [Related Packages](#related-packages)
- [Contributing](#contributing)
- [License](#license)

## Why swift-io?

Swift's cooperative thread pool is not designed for blocking I/O. This library exists to solve problems that arise when mixing async/await with syscalls:

| Problem | Cooperative Pool | swift-io |
|---------|------------------|----------|
| **Blocking syscalls** | Starves cooperative threads | Dedicated thread pool isolates blocking work |
| **Waiter management** | Manual continuation handling | Bounded FIFO queues with backpressure |
| **Resource cleanup** | Manual, error-prone | Deterministic teardown strategies |
| **Cancellation** | Inconsistent semantics | Well-defined: before/after acceptance |
| **Move-only resources** | No native support | Generic over `~Copyable` with slot pattern |
| **Error handling** | Untyped throws | Typed throws with `IO.Error<E>` |

If you need async I/O that doesn't starve your cooperative pool, bounded resource contention, or deterministic cleanup semantics, this library provides the infrastructure.

## Overview

swift-io provides an actor-based executor pool for managing resources with async I/O operations. Built on a dedicated thread pool that isolates blocking syscalls from Swift's cooperative executor.

The library is structured in layers:
- **IO Primitives**: Core namespace and re-exports
- **IO Blocking**: Lane abstraction for blocking execution
- **IO Blocking Threads**: Thread pool implementation
- **IO**: Executor pool with handle management

## Design Principles

- **Typed throws**: Every function declares its error type. `IO.Error<E>` preserves operation errors.
- **Nested types**: API reads naturally: `IO.Executor.Pool`, `IO.Handle.ID`, not `IOExecutorPool`.
- **Move-only resources**: Generic over `~Copyable`. Resources never escape actor isolation.
- **Bounded queues**: Waiter queues have configurable capacity. Backpressure suspends callers.
- **Single execution point**: All state transitions return actions executed outside locks.

## Design Guarantees

### What this library guarantees

- **Exactly-once resumption**: Every waiter continuation is resumed exactly once. Double-resume is structurally prevented.
- **FIFO fairness**: Waiters are resumed in registration order (best effort under contention).
- **Bounded memory**: Waiter queues are capacity-limited. Registration fails with `.full` when exceeded.
- **Deterministic shutdown**: In-flight operations complete; waiters are notified; resources are torn down in order.
- **No data races**: Full Swift 6 strict concurrency compliance with `Sendable` types throughout.
- **Cancellation safety**: Cancellation never leaves resources in inconsistent state.

### What this library does NOT guarantee

- **Syscall interruption**: Cancellation after acceptance does not interrupt running syscalls.
- **Exact FIFO under contention**: Actor scheduling may reorder concurrent operations.
- **Cross-process coordination**: No distributed locking primitives.

## Features

- **Actor-based pool**: `IO.Executor.Pool<Resource>` manages resources with exclusive transaction access
- **Dedicated thread pool**: Blocking I/O runs on separate threads, never starves Swift's cooperative pool
- **Move-only resources**: Generic over `~Copyable` with slot pattern for cross-await transport
- **Bounded waiter queues**: Configurable capacity with FIFO resumption and backpressure
- **Typed error handling**: `IO.Error<E>` preserves operation-specific errors
- **Deterministic teardown**: Configurable strategies (`.drop()`, `.run(_:)`) for resource cleanup
- **Scoped handle IDs**: `IO.Handle.ID` includes scope to prevent cross-pool confusion
- **Swift 6 strict concurrency**: Full `Sendable` compliance, no data races

## Installation

Add swift-io to your Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/coenttb/swift-io.git", from: "0.1.0")
]
```

Add to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "IO", package: "swift-io"),
    ]
)
```

### Requirements

- Swift 6.2+
- macOS 26.0+, iOS 26.0+, or Linux

## Quick Start

### Basic Executor Pool

```swift
import IO

// Create a pool for your resource type
let pool = IO.Executor.Pool<MyResource>()

// Register a resource
let id = try await pool.register {
    try MyResource.open(path)
}

// Execute operations with exclusive access
let result = try await pool.transaction(id) { resource in
    try resource.read()
}

// Destroy when done
try await pool.destroy(id)

// Shutdown the pool
await pool.shutdown()
```

### Running Blocking Operations

```swift
// Run a blocking operation on the dedicated thread pool
let data = try await pool.run {
    try blockingSyscall()
}
```

### Transaction-Based Access

```swift
// Transactions provide exclusive access to a resource
try await pool.transaction(handleID) { resource in
    // Only this closure can access the resource
    try resource.write(data)
    return try resource.read()
}
```

## Usage Examples

### Custom Teardown Strategy

```swift
// Resources are torn down deterministically on shutdown
let pool = IO.Executor.Pool<FileHandle>(
    teardown: .run { handle in
        try? handle.close()
    }
)
```

### Configuring the Thread Pool

```swift
// Custom thread pool options
let pool = IO.Executor.Pool<MyResource>(
    IO.Blocking.Threads.Options(
        workers: 4,
        queueLimit: 128
    ),
    handleWaitersLimit: 32
)
```

### Handle ID Validation

```swift
// Handle IDs include scope for safety
let id = try pool.register(resource)

// Check if handle belongs to this pool
if pool.isOpen(id) {
    try await pool.transaction(id) { ... }
}

// Wrong scope throws .scopeMismatch
do {
    try await otherPool.transaction(id) { ... }
} catch .handle(.scopeMismatch) {
    // ID belongs to different pool
}
```

### Error Handling

```swift
// IO.Error preserves your operation's error type
do {
    let result = try await pool.run {
        try myOperation()  // throws MyError
    }
} catch .operation(let error) {
    // error is MyError
} catch .executor(.shutdownInProgress) {
    // Pool is shutting down
} catch .cancelled {
    // Task was cancelled
}
```

### Using the Lane Directly

```swift
// For simple blocking operations without resource management
let lane = IO.Blocking.Lane.threads()

let result = try await lane.run(deadline: nil) {
    try blockingOperation()
}

await lane.shutdown()
```

## Architecture

### Layers

```
┌─────────────────────────────────────────────┐
│                    IO                        │  ← Public API: Pool, Handle.ID, Error
├─────────────────────────────────────────────┤
│              IO Blocking                     │  ← Lane abstraction, Failure types
├─────────────────────────────────────────────┤
│           IO Blocking Threads                │  ← Thread pool implementation
├─────────────────────────────────────────────┤
│              IO Primitives                   │  ← Core namespace, re-exports
└─────────────────────────────────────────────┘
```

### Key Types

| Type | Purpose |
|------|---------|
| `IO.Executor.Pool<Resource>` | Actor-based resource pool with transaction access |
| `IO.Handle.ID` | Scoped identifier for registered resources |
| `IO.Blocking.Lane` | Execution backend for blocking operations |
| `IO.Error<E>` | Typed error wrapper preserving operation errors |
| `IO.Executor.Teardown<Resource>` | Strategy for resource cleanup on shutdown |

### Execution Model

```
Swift Task                    Lane (Thread Pool)
    │                              │
    ├─── run(operation) ──────────►│
    │    (suspends)                │
    │                              ├─── execute on worker thread
    │                              │
    │◄── resume with result ───────┤
    │                              │
```

### Waiter Queue Design

The waiter queue uses a two-phase lifecycle with type-level guarantees:

1. **Register**: Creates a ticket identity observable to cancellation
2. **Arm**: Attaches continuation, makes eligible for FIFO resumption

This eliminates TOCTOU races where cancellation could fire before the continuation is enqueued.

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS | Full | Primary development platform |
| iOS | Full | Same as macOS |
| Linux | Full | POSIX threads |
| Windows | Build ✅ | Tests pending toolchain fixes |

## Related Packages

### Dependencies

- [swift-time-standard](https://github.com/swift-standards/swift-time-standard): Time types for deadlines
- [swift-standards](https://github.com/swift-standards/swift-standards): Test support utilities

### See Also

- [swift-file-system](https://github.com/coenttb/swift-file-system): File system operations built on swift-io

## Contributing

Contributions welcome. Please:

1. Add tests - maintain coverage for new features
2. Follow conventions - Swift 6, strict concurrency, no force-unwraps
3. Update docs - inline documentation and README updates

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.
