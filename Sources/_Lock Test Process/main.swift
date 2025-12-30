//
//  main.swift
//  _Lock Test Process
//
//  A helper executable for multi-process file locking tests.
//
//  Usage:
//    _Lock\ Test\ Process <command> <file> [options]
//
//  Commands:
//    lock-exclusive <file>       Acquire exclusive lock, wait for signal, release
//    lock-shared <file>          Acquire shared lock, wait for signal, release
//    try-exclusive <file>        Try to acquire exclusive lock (non-blocking)
//    try-shared <file>           Try to acquire shared lock (non-blocking)
//    deadline-exclusive <file>   Acquire exclusive lock with deadline
//    deadline-shared <file>      Acquire shared lock with deadline
//
//  Options:
//    --range <start>-<end>       Lock byte range (default: whole file)
//    --hold <seconds>            Hold lock for N seconds instead of waiting for stdin
//    --deadline-ms <ms>          Deadline in milliseconds (for deadline-* commands)
//    --signal-ready              Print "READY" when lock is acquired
//
//  Exit codes:
//    0  Success (lock acquired, or released)
//    1  Lock would block (for try-* commands)
//    2  Lock timed out (for deadline-* commands)
//    3  Error (invalid arguments, file not found, etc.)
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

import Kernel

// MARK: - Argument Parsing

struct Arguments {
    enum Command {
        case lockExclusive
        case lockShared
        case tryExclusive
        case tryShared
        case deadlineExclusive
        case deadlineShared
    }

    let command: Command
    let filePath: String
    var range: Kernel.Lock.Range = .file
    var holdSeconds: Int? = nil
    var deadlineMs: Int = 1000  // Default 1 second
    var signalReady: Bool = false
}

func parseArguments() -> Arguments? {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        printUsage()
        return nil
    }

    let commandStr = args[1]
    let filePath = args[2]

    let command: Arguments.Command
    switch commandStr {
    case "lock-exclusive":
        command = .lockExclusive
    case "lock-shared":
        command = .lockShared
    case "try-exclusive":
        command = .tryExclusive
    case "try-shared":
        command = .tryShared
    case "deadline-exclusive":
        command = .deadlineExclusive
    case "deadline-shared":
        command = .deadlineShared
    default:
        fputs("Unknown command: \(commandStr)\n", stderr)
        printUsage()
        return nil
    }

    var result = Arguments(command: command, filePath: filePath)

    // Parse optional arguments
    var i = 3
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--range":
            guard i + 1 < args.count else {
                fputs("--range requires an argument\n", stderr)
                return nil
            }
            i += 1
            let rangeStr = args[i]
            let parts = rangeStr.split(separator: "-")
            guard parts.count == 2,
                  let start = UInt64(parts[0]),
                  let end = UInt64(parts[1]) else {
                fputs("Invalid range format. Use: start-end\n", stderr)
                return nil
            }
            result.range = .bytes(start: start, end: end)

        case "--hold":
            guard i + 1 < args.count else {
                fputs("--hold requires an argument\n", stderr)
                return nil
            }
            i += 1
            guard let seconds = Int(args[i]) else {
                fputs("Invalid hold seconds\n", stderr)
                return nil
            }
            result.holdSeconds = seconds

        case "--deadline-ms":
            guard i + 1 < args.count else {
                fputs("--deadline-ms requires an argument\n", stderr)
                return nil
            }
            i += 1
            guard let ms = Int(args[i]) else {
                fputs("Invalid deadline milliseconds\n", stderr)
                return nil
            }
            result.deadlineMs = ms

        case "--signal-ready":
            result.signalReady = true

        default:
            fputs("Unknown option: \(arg)\n", stderr)
            return nil
        }
        i += 1
    }

    return result
}

func printUsage() {
    let usage = """
    Usage: _Lock\\ Test\\ Process <command> <file> [options]

    Commands:
      lock-exclusive <file>       Acquire exclusive lock, wait, release
      lock-shared <file>          Acquire shared lock, wait, release
      try-exclusive <file>        Try exclusive lock (non-blocking)
      try-shared <file>           Try shared lock (non-blocking)
      deadline-exclusive <file>   Acquire exclusive lock with deadline
      deadline-shared <file>      Acquire shared lock with deadline

    Options:
      --range <start>-<end>       Lock byte range (default: whole file)
      --hold <seconds>            Hold lock for N seconds
      --deadline-ms <ms>          Deadline in milliseconds (default: 1000)
      --signal-ready              Print "READY" when lock acquired

    Exit codes:
      0  Success
      1  Lock would block (try-* commands)
      2  Lock timed out (deadline-* commands)
      3  Error
    """
    fputs(usage, stderr)
    fputs("\n", stderr)
}

// MARK: - Main

#if !os(Windows)

func main() -> Int32 {
    guard let args = parseArguments() else {
        return 3
    }

    // Open the file
    let fd = open(args.filePath, O_RDWR)
    guard fd >= 0 else {
        fputs("Failed to open file: \(args.filePath)\n", stderr)
        return 3
    }
    defer { close(fd) }

    let kind: Kernel.Lock.Kind
    let acquire: Kernel.Lock.Acquire

    switch args.command {
    case .lockExclusive:
        kind = .exclusive
        acquire = .wait
    case .lockShared:
        kind = .shared
        acquire = .wait
    case .tryExclusive:
        kind = .exclusive
        acquire = .try
    case .tryShared:
        kind = .shared
        acquire = .try
    case .deadlineExclusive:
        kind = .exclusive
        acquire = .timeout(.milliseconds(args.deadlineMs))
    case .deadlineShared:
        kind = .shared
        acquire = .timeout(.milliseconds(args.deadlineMs))
    }

    // Acquire lock
    var token: Kernel.Lock.Token
    do {
        token = try Kernel.Lock.Token(
            descriptor: fd,
            range: args.range,
            kind: kind,
            acquire: acquire
        )
    } catch {
        switch error {
        case .contention:
            // Could be wouldBlock or timedOut
            if case .try = acquire {
                fputs("WOULD_BLOCK\n", stdout)
                fflush(stdout)
                return 1
            } else {
                fputs("TIMED_OUT\n", stdout)
                fflush(stdout)
                return 2
            }
        default:
            fputs("Failed to acquire lock: \(error)\n", stderr)
            return 3
        }
    }

    // Signal ready if requested
    if args.signalReady {
        fputs("READY\n", stdout)
        fflush(stdout)
    }

    // Hold lock
    if let seconds = args.holdSeconds {
        sleep(UInt32(seconds))
    } else {
        // Wait for newline on stdin
        var buffer = [CChar](repeating: 0, count: 2)
        _ = read(STDIN_FILENO, &buffer, 1)
    }

    // Release lock
    token.release()

    fputs("RELEASED\n", stdout)
    fflush(stdout)

    return 0
}

exit(main())

#else

// Windows implementation
func main() -> Int32 {
    guard let args = parseArguments() else {
        return 3
    }

    // Open the file
    let handle = args.filePath.withCString(encodedAs: UTF16.self) { widePath in
        CreateFileW(
            widePath,
            DWORD(GENERIC_READ | GENERIC_WRITE),
            0,  // No sharing
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_ATTRIBUTE_NORMAL),
            nil
        )
    }

    guard handle != INVALID_HANDLE_VALUE else {
        fputs("Failed to open file: \(args.filePath)\n", stderr)
        return 3
    }
    defer { CloseHandle(handle) }

    let kind: Kernel.Lock.Kind
    let acquire: Kernel.Lock.Acquire

    switch args.command {
    case .lockExclusive:
        kind = .exclusive
        acquire = .wait
    case .lockShared:
        kind = .shared
        acquire = .wait
    case .tryExclusive:
        kind = .exclusive
        acquire = .try
    case .tryShared:
        kind = .shared
        acquire = .try
    case .deadlineExclusive:
        kind = .exclusive
        acquire = .timeout(.milliseconds(args.deadlineMs))
    case .deadlineShared:
        kind = .shared
        acquire = .timeout(.milliseconds(args.deadlineMs))
    }

    // Acquire lock
    var token: Kernel.Lock.Token
    do {
        token = try Kernel.Lock.Token(
            descriptor: handle,
            range: args.range,
            kind: kind,
            acquire: acquire
        )
    } catch {
        switch error {
        case .contention:
            // Could be wouldBlock or timedOut
            if case .try = acquire {
                fputs("WOULD_BLOCK\n", stdout)
                fflush(stdout)
                return 1
            } else {
                fputs("TIMED_OUT\n", stdout)
                fflush(stdout)
                return 2
            }
        default:
            fputs("Failed to acquire lock: \(error)\n", stderr)
            return 3
        }
    }

    // Signal ready if requested
    if args.signalReady {
        fputs("READY\n", stdout)
        fflush(stdout)
    }

    // Hold lock
    if let seconds = args.holdSeconds {
        Sleep(DWORD(seconds * 1000))
    } else {
        // Wait for newline on stdin
        var buffer: CChar = 0
        var bytesRead: DWORD = 0
        let stdinHandle = GetStdHandle(STD_INPUT_HANDLE)
        _ = ReadFile(stdinHandle, &buffer, 1, &bytesRead, nil)
    }

    // Release lock
    token.release()

    fputs("RELEASED\n", stdout)
    fflush(stdout)

    return 0
}

exit(main())

#endif
