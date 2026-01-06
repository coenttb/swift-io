//
//  IO.Event.Channel.Shutdown.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

public import Kernel

extension IO.Event.Channel {
    /// Accessor for shutdown operations.
    ///
    /// Provides the `shutdown.read()` and `shutdown.write()` methods
    /// for half-close operations on a channel.
    public struct Shutdown: ~Copyable {
        /// Reference to the channel's lifecycle actor.
        private let lifecycle: Lifecycle

        /// Reference to the descriptor for syscalls.
        private let descriptor: Kernel.Descriptor

        /// Internal initializer.
        init(lifecycle: Lifecycle, descriptor: Kernel.Descriptor) {
            self.lifecycle = lifecycle
            self.descriptor = descriptor
        }

        /// Shutdown the read direction.
        ///
        /// After this call, reads return 0 (EOF). The kernel may send
        /// a FIN to the peer depending on the socket type.
        ///
        /// This operation is idempotent - calling it multiple times is a no-op.
        ///
        /// - Throws: `Failure` on error.
        public func read() async throws(IO.Event.Failure) {
            // Idempotent - no-op if already read-closed
            if await lifecycle.isReadClosed {
                return
            }
            await lifecycle.close.read()

            // Perform syscall, normalize errors for idempotence
            do {
                try Kernel.Socket.Shutdown.shutdown(
                    Kernel.Socket.Descriptor(descriptor),
                    how: .read
                )
            } catch {
                // Ignore most shutdown errors for idempotence:
                // - ENOTCONN (not connected) is expected for datagram sockets
                // - EINVAL (invalid) can mean already shut down
                // Only propagate serious I/O errors
                if case .io(let ioError) = error {
                    // Propagate hardware/reset errors
                    switch ioError {
                    case .hardware, .reset:
                        throw .failure(IO.Event.Error(error))
                    default:
                        break
                    }
                }
            }
        }

        /// Shutdown the write direction.
        ///
        /// After this call, writes throw `.failure(.writeClosed)`.
        /// The kernel sends a FIN to the peer.
        ///
        /// This operation is idempotent - calling it multiple times is a no-op.
        ///
        /// - Throws: `Failure` on error.
        public func write() async throws(IO.Event.Failure) {
            // Idempotent - no-op if already write-closed
            if await lifecycle.isWriteClosed {
                return
            }
            await lifecycle.close.write()

            // Perform syscall, normalize errors for idempotence
            do {
                try Kernel.Socket.Shutdown.shutdown(
                    Kernel.Socket.Descriptor(descriptor),
                    how: .write
                )
            } catch {
                // Ignore most shutdown errors for idempotence:
                // - ENOTCONN (not connected) is expected for datagram sockets
                // - EINVAL (invalid) can mean already shut down
                // Only propagate serious I/O errors
                if case .io(let ioError) = error {
                    // Propagate hardware/reset errors
                    switch ioError {
                    case .hardware, .reset:
                        throw .failure(IO.Event.Error(error))
                    default:
                        break
                    }
                }
            }
        }
    }

}
