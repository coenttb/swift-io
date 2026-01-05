//
//  IO.Event.Token.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

public import Kernel

extension IO.Event {
    /// Move-only capability token for selector API safety.
    ///
    /// Tokens use typestate to enforce correct API usage at compile time:
    /// - `Token<Registering>`: Just registered, can be armed or cancelled
    /// - `Token<Armed>`: Waiting for readiness, can be modified, deregistered, or cancelled
    /// - `Token<Completed>`: Event received or cancelled, no further operations
    ///
    /// ## Design
    /// - **Move-only** (`~Copyable`): Prevents use-after-consume bugs
    /// - **Phase-typed**: Wrong-state operations are compile-time errors
    /// - **Sendable**: Safe to pass across isolation boundaries
    ///
    /// ## Distinction from Kernel.Handoff.Token
    /// - `IO.Event.Token<Phase>`: API safety (typestate for selector operations)
    /// - `Kernel.Handoff.Token`: Ownership transfer of ~Copyable values across @Sendable boundaries
    ///
    /// ## Phases (defined in IO.Event namespace)
    /// - `Registering`: Initial phase after registration
    /// - `Armed`: Waiting for readiness events
    /// - `Completed`: Operation finished
    ///
    /// ## State Machine
    /// ```
    /// register() → Token<Registering>
    ///     │
    ///     ├─ arm()     → Token<Armed> + Event
    ///     │                 │
    ///     │                 ├─ modify()     → (borrows token)
    ///     │                 ├─ deregister() → consumes token
    ///     │                 └─ cancel()     → Token<Completed>
    ///     │
    ///     └─ cancel()  → Token<Completed>
    /// ```
    public struct Token<Phase>: ~Copyable, Sendable {
        /// The registration ID this token represents.
        public let id: ID

        /// Creates a token for the given ID.
        ///
        /// Tokens are created by selector operations, not by user code.
        @usableFromInline
        package init(id: ID) {
            self.id = id
        }
    }
}
