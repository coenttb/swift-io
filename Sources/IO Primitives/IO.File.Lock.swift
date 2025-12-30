//
//  IO.File.Lock.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 30/12/2025.
//

// File locking has moved to swift-kernel.
// Use `Kernel.Lock` directly from swift-kernel.
//
// Migration guide:
// - IO.File.Lock.Mode     -> Kernel.Lock.Kind
// - IO.File.Lock.Range    -> Kernel.Lock.Range
// - IO.File.Lock.Acquire  -> Kernel.Lock.Acquire
// - IO.File.Lock.Token    -> Kernel.Lock.Token
// - IO.File.Lock.Error    -> Kernel.Lock.Error
