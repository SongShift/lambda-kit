# DynamoQueriesDemo

A focused demo of the `DynamoQueries` library against an in-memory recording
client. Walks through the operations you'll reach for most: query, scan,
put-if-not-exists, optimistic-concurrency update, batch write, and transact
write.

```sh
swift run DynamoQueriesDemo
```

The demo doesn't talk to real DynamoDB — it uses a tiny `RecordingClient`
that captures every input the DSL produces, prints the rendered DynamoDB
expression strings, and (for the operations that return data) hands back
canned responses. That makes it easy to see exactly what wire-level request
each Swift call site builds.

If you want to run the same DSL against real DynamoDB, swap the client for
`SotoDynamoClient(database: ...)` from `DynamoQueriesSoto`.

Read the source in [Sources/main.swift](Sources/main.swift).
