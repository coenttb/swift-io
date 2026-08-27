#if !os(Windows)
    public import Either
    public import Async

    extension Event {

        public typealias Failure = Either<Async.Lifecycle.Error, Event.Error>
    }

#endif
