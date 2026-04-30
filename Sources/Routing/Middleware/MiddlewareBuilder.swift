//
//  MiddlewareBuilder.swift
//
//  Created by Ben Rosen on 4/7/26.
//  Copyright © 2026 SongShift, LLC. All rights reserved.
//

//  The result builder behind `Router.withMiddleware { ... }` and
//  `RouteGroup.withMiddleware { ... }`. Each `buildBlock` overload chains its
//  arguments left-to-right via the `.chain` combinator from
//  `MiddlewareCombinators.swift`. We hand-roll one overload per arity (1...5)
//  rather than using variadic generics to keep the produced type explicit at
//  every call site — the user of the result builder sees the chained type in
//  errors and IDE inspection.
//

// MARK: - Result Builder

@resultBuilder
public enum MiddlewareBuilder {
    public static func buildBlock<M0: MiddlewareProtocol>(
        _ m0: M0
    ) -> M0 {
        m0
    }

    public static func buildBlock<M0: MiddlewareProtocol, M1: MiddlewareProtocol>(
        _ m0: M0, _ m1: M1
    ) -> ChainedMiddleware<M0, M1> where M0.Output == M1.Input {
        m0.chain(m1)
    }

    public static func buildBlock<
        M0: MiddlewareProtocol,
        M1: MiddlewareProtocol,
        M2: MiddlewareProtocol
    >(
        _ m0: M0, _ m1: M1, _ m2: M2
    ) -> ChainedMiddleware<ChainedMiddleware<M0, M1>, M2>
        where M0.Output == M1.Input, M1.Output == M2.Input {
        m0.chain(m1).chain(m2)
    }

    public static func buildBlock<
        M0: MiddlewareProtocol,
        M1: MiddlewareProtocol,
        M2: MiddlewareProtocol,
        M3: MiddlewareProtocol
    >(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3
    ) -> ChainedMiddleware<ChainedMiddleware<ChainedMiddleware<M0, M1>, M2>, M3>
        where M0.Output == M1.Input, M1.Output == M2.Input, M2.Output == M3.Input {
        m0.chain(m1).chain(m2).chain(m3)
    }

    public static func buildBlock<
        M0: MiddlewareProtocol,
        M1: MiddlewareProtocol,
        M2: MiddlewareProtocol,
        M3: MiddlewareProtocol,
        M4: MiddlewareProtocol
    >(
        _ m0: M0, _ m1: M1, _ m2: M2, _ m3: M3, _ m4: M4
    ) -> ChainedMiddleware<ChainedMiddleware<
        ChainedMiddleware<ChainedMiddleware<M0, M1>, M2>,
        M3
    >, M4>
        where M0.Output == M1.Input, M1.Output == M2.Input, M2.Output == M3.Input,
        M3.Output == M4.Input {
        m0.chain(m1).chain(m2).chain(m3).chain(m4)
    }

    public static func buildOptional<M: MiddlewareProtocol>(
        _ middleware: M?
    ) -> OptionalMiddleware<M> where M.Output == M.Input {
        OptionalMiddleware(middleware: middleware)
    }

    public static func buildEither<A: MiddlewareProtocol, B: MiddlewareProtocol>(
        first: A
    ) -> EitherMiddleware<A, B> where A.Input == B.Input, A.Output == B.Output {
        EitherMiddleware(storage: .left(first))
    }

    public static func buildEither<A: MiddlewareProtocol, B: MiddlewareProtocol>(
        second: B
    ) -> EitherMiddleware<A, B> where A.Input == B.Input, A.Output == B.Output {
        EitherMiddleware(storage: .right(second))
    }
}
