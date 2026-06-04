import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct DynamoKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TableMacro.self,
        PartitionKeyMacro.self,
        SortKeyMacro.self,
        AttributeMacro.self,
        ExpressionValueMacro.self,
        IndexMacro.self,
    ]
}
