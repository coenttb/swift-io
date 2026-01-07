//
//  Result+catching.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 07/01/2026.
//

extension Result {
    /// Creates a Result from a typed-throws closure.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let result: Result<Int, MyError> = Result {
    ///     try mightFail()  // throws(MyError)
    /// }
    /// ```
    ///
    /// This differs from the standard library's `Result.init(catching:)` which
    /// uses untyped throws. This version preserves the typed error.
    ///
    /// ## Typed Catch
    ///
    /// Inside this initializer, `catch { }` binds `error` as `Failure` (typed),
    /// not `any Error`, because the closure signature is `throws(Failure)`.
    @inlinable
    public init(catching body: () throws(Failure) -> Success) {
        do {
            self = .success(try body())
        } catch {
            self = .failure(error)
        }
    }
}
