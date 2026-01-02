//
//  IO.Completion.IOUring.Ring.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 02/01/2026.
//

#if os(Linux)

    import Kernel
    import MMap
    import CLinuxShim  // For io_uring_sqe/cqe C types

    extension IO.Completion.IOUring {
        /// Poll-thread-confined ring state for io_uring.
        ///
        /// This class holds all mmap'd ring memory and cached pointers for fast access.
        /// It is `@unchecked Sendable` because all access happens on the poll thread.
        ///
        /// ## Memory Layout
        ///
        /// io_uring uses three memory regions:
        /// - **SQ Ring**: Contains head, tail, mask, flags, and array of SQE indices
        /// - **CQ Ring**: Contains head, tail, mask, overflow, and CQE array
        /// - **SQE Array**: The actual submission queue entries
        ///
        /// ## Ownership
        ///
        /// - Created by `create()` and stored in `Handle.ringPtr`
        /// - Retrieved via `Unmanaged` pointer recovery
        /// - Released in `close()` via `takeRetainedValue()`
        /// - `deinit` automatically unmaps all regions
        final class Ring: @unchecked Sendable {
            /// The io_uring file descriptor.
            let fd: Kernel.Descriptor

            /// Parameters returned by io_uring_setup.
            let params: Kernel.IOUring.Params

            // MARK: - Mmap'd Regions

            /// Submission queue ring memory.
            var sqRing: MMap.Region

            /// Completion queue ring memory.
            var cqRing: MMap.Region

            /// Submission queue entries array.
            var sqeArray: MMap.Region

            // MARK: - Cached SQ Pointers

            /// Pointer to SQ head (kernel updates this).
            let sqHead: UnsafeMutablePointer<UInt32>

            /// Pointer to SQ tail (we update this).
            let sqTail: UnsafeMutablePointer<UInt32>

            /// SQ ring mask for index wrapping.
            let sqMask: UInt32

            /// Pointer to SQ index array.
            let sqArray: UnsafeMutablePointer<UInt32>

            /// Pointer to SQE array.
            let sqes: UnsafeMutablePointer<io_uring_sqe>

            // MARK: - Cached CQ Pointers

            /// Pointer to CQ head (we update this).
            let cqHead: UnsafeMutablePointer<UInt32>

            /// Pointer to CQ tail (kernel updates this).
            let cqTail: UnsafeMutablePointer<UInt32>

            /// CQ ring mask for index wrapping.
            let cqMask: UInt32

            /// Pointer to CQE array.
            let cqes: UnsafeMutablePointer<io_uring_cqe>

            // MARK: - Local State

            /// Local SQ tail for batching.
            ///
            /// This tracks our local writes before we flush to the kernel.
            /// Updated immediately on submit, only written to `sqTail` on flush.
            var localSqTail: UInt32

            // MARK: - Initialization

            /// Creates a ring state from an io_uring fd and params.
            ///
            /// Maps all three memory regions and caches pointers for fast access.
            ///
            /// - Parameters:
            ///   - fd: The io_uring file descriptor from `io_uring_setup`.
            ///   - params: The params filled by `io_uring_setup`.
            /// - Throws: `IO.Completion.Error` if mapping fails.
            init(fd: Kernel.Descriptor, params: Kernel.IOUring.Params) throws(IO.Completion.Error) {
                self.fd = fd
                self.params = params

                // Calculate ring sizes based on params
                let sqRingSize = Int(params.sqOff.array) + Int(params.sqEntries) * MemoryLayout<UInt32>.size
                let cqRingSize = Int(params.cqOff.cqes) + Int(params.cqEntries) * MemoryLayout<io_uring_cqe>.size
                let sqeArraySize = Int(params.sqEntries) * MemoryLayout<io_uring_sqe>.size

                // Map SQ ring
                do {
                    self.sqRing = try MMap.Region(
                        fileDescriptor: fd,
                        mmapOffset: Kernel.IOUring.MmapOffset.sqRing,
                        length: sqRingSize,
                        access: [.read, .write],
                        sharing: .shared
                    )
                } catch {
                    throw .kernel(.memory(.exhausted))
                }

                // Map CQ ring
                do {
                    self.cqRing = try MMap.Region(
                        fileDescriptor: fd,
                        mmapOffset: Kernel.IOUring.MmapOffset.cqRing,
                        length: cqRingSize,
                        access: [.read, .write],
                        sharing: .shared
                    )
                } catch {
                    throw .kernel(.memory(.exhausted))
                }

                // Map SQE array
                do {
                    self.sqeArray = try MMap.Region(
                        fileDescriptor: fd,
                        mmapOffset: Kernel.IOUring.MmapOffset.sqes,
                        length: sqeArraySize,
                        access: [.read, .write],
                        sharing: .shared
                    )
                } catch {
                    throw .kernel(.memory(.exhausted))
                }

                // Cache SQ pointers
                guard let sqBase = sqRing.mutableBaseAddress else {
                    throw .kernel(.memory(.address))
                }

                self.sqHead = sqBase.advanced(by: Int(params.sqOff.head)).assumingMemoryBound(to: UInt32.self)
                self.sqTail = sqBase.advanced(by: Int(params.sqOff.tail)).assumingMemoryBound(to: UInt32.self)
                self.sqMask = sqBase.advanced(by: Int(params.sqOff.ringMask)).load(as: UInt32.self)
                self.sqArray = sqBase.advanced(by: Int(params.sqOff.array)).assumingMemoryBound(to: UInt32.self)

                // Cache SQE pointer
                guard let sqeBase = sqeArray.mutableBaseAddress else {
                    throw .kernel(.memory(.address))
                }
                self.sqes = sqeBase.assumingMemoryBound(to: io_uring_sqe.self)

                // Cache CQ pointers
                guard let cqBase = cqRing.mutableBaseAddress else {
                    throw .kernel(.memory(.address))
                }

                self.cqHead = cqBase.advanced(by: Int(params.cqOff.head)).assumingMemoryBound(to: UInt32.self)
                self.cqTail = cqBase.advanced(by: Int(params.cqOff.tail)).assumingMemoryBound(to: UInt32.self)
                self.cqMask = cqBase.advanced(by: Int(params.cqOff.ringMask)).load(as: UInt32.self)
                self.cqes = cqBase.advanced(by: Int(params.cqOff.cqes)).assumingMemoryBound(to: io_uring_cqe.self)

                // Initialize local tail to current kernel tail
                self.localSqTail = self.sqTail.pointee
            }

            deinit {
                // MMap.Region handles unmapping in its deinit
                // We just need to close the fd
                Kernel.IOUring.close(fd)
            }
        }
    }

    // MARK: - SQE Access

    extension IO.Completion.IOUring.Ring {
        /// Gets the next available SQE slot.
        ///
        /// - Returns: Pointer to the next SQE, or nil if the ring is full.
        func getNextSQE() -> UnsafeMutablePointer<io_uring_sqe>? {
            // Check if ring is full
            let head = Kernel.Atomic.load(sqHead, ordering: .acquiring)
            let tail = localSqTail
            let available = params.sqEntries &- (tail &- head)

            guard available > 0 else {
                return nil
            }

            let index = tail & sqMask
            return sqes.advanced(by: Int(index))
        }

        /// Advances the local SQ tail after filling an SQE.
        func advanceSQTail() {
            // Update the SQ array with the SQE index
            let tail = localSqTail
            let index = tail & sqMask
            sqArray[Int(index)] = index

            // Advance local tail
            localSqTail = tail &+ 1
        }

        /// Returns the number of pending submissions.
        var pendingSubmissions: UInt32 {
            localSqTail &- Kernel.Atomic.load(sqTail, ordering: .acquiring)
        }
    }

#endif
