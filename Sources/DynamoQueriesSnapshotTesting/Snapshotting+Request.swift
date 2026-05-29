import DynamoQueries
import DynamoQueriesTestSupport
import SnapshotTesting

extension Snapshotting where Value: RenderableRequest, Format == String {
    /// A snapshot strategy that compares a DynamoDB request by its rendered
    /// form .
    ///
    /// ```swift
    /// assertInlineSnapshot(
    ///   of: Hike.query { Key { $0.hikerID == "hiker-1" } },
    ///   as: .request
    /// ) {
    ///   """
    ///   Query DemoHikes
    ///     key: #n0 = :v0
    ///     names: { #n0: hikerID }
    ///     values: { :v0: S("hiker-1") }
    ///   """
    /// }
    /// ```
    ///
    public static var request: Snapshotting {
        SimplySnapshotting.lines.pullback(\.renderedRequest)
    }
}
