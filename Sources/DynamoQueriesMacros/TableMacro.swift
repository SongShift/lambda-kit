import SwiftSyntax
import SwiftSyntaxMacros
import SwiftParser

public struct TableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Extract table name from @Table("tableName")
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let firstArgument = arguments.first,
              let stringLiteral = firstArgument.expression.as(StringLiteralExprSyntax.self),
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
        else {
            throw DiagnosticError("@Table requires a string literal argument")
        }
        let tableName = segment.content.text

        // Must be attached to a struct
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticError("@Table can only be applied to structs")
        }

        let typeName = type.trimmedDescription

        // Collect property metadata
        var partitionKeyName: String?
        var sortKeyName: String?
        var properties: [(swiftName: String, dynamoName: String, typeName: String)] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation?.type
            else { continue }

            // Skip computed properties
            if let accessors = binding.accessorBlock {
                let hasGetter = accessors.accessors.description.contains("get")
                if hasGetter { continue }
            }

            let swiftName = pattern.identifier.text
            let propertyType = typeAnnotation.trimmedDescription

            // Check for @Attribute("customName")
            var dynamoName = swiftName
            for attribute in varDecl.attributes {
                if let attributeSyntax = attribute.as(AttributeSyntax.self),
                   attributeSyntax.attributeName.trimmedDescription == "Attribute",
                   let arguments = attributeSyntax.arguments?.as(LabeledExprListSyntax.self),
                   let argument = arguments.first,
                   let literal = argument.expression.as(StringLiteralExprSyntax.self),
                   let segment = literal.segments.first?.as(StringSegmentSyntax.self) {
                    dynamoName = segment.content.text
                }
            }

            // Check for @PartitionKey
            let isPartitionKey = varDecl.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "PartitionKey"
            }
            if isPartitionKey {
                partitionKeyName = dynamoName
            }

            // Check for @SortKey
            let isSortKey = varDecl.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "SortKey"
            }
            if isSortKey {
                sortKeyName = dynamoName
            }

            properties.append((swiftName: swiftName, dynamoName: dynamoName, typeName: propertyType))
        }

        guard let resolvedPartitionKey = partitionKeyName else {
            throw DiagnosticError("@Table struct must have exactly one @PartitionKey property")
        }

        // Collect sibling @Index annotations on the struct
        let indexes: [(swiftName: String, partitionKey: String, sortKey: String?)] =
            structDecl.attributes.compactMap { element in
                guard let attributeSyntax = element.as(AttributeSyntax.self),
                      attributeSyntax.attributeName.trimmedDescription == "Index",
                      let arguments = attributeSyntax.arguments?.as(LabeledExprListSyntax.self)
                else { return nil }

                var indexName: String?
                var indexPartition: String?
                var indexSort: String?

                for argument in arguments {
                    guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                          let segment = literal.segments.first?.as(StringSegmentSyntax.self)
                    else { continue }
                    let value = segment.content.text

                    switch argument.label?.text {
                    case nil:
                        indexName = value
                    case "partitionKey":
                        indexPartition = value
                    case "sortKey":
                        indexSort = value
                    default:
                        break
                    }
                }

                guard let indexName, let indexPartition else { return nil }
                return (swiftName: indexName, partitionKey: indexPartition, sortKey: indexSort)
            }

        // Detect access level — match the struct's visibility
        let accessLevel: String
        if let modifiers = structDecl.modifiers.first(where: {
            $0.name.tokenKind == .keyword(.public)
        }) {
            accessLevel = "public "
        } else {
            accessLevel = ""
        }

        // Build the extension source
        let sortKeyExpr = sortKeyName.map { "\"\($0)\"" } ?? "nil"

        let attributeDecls = properties.map { property in
            "        \(accessLevel)static let \(property.swiftName) = Attribute<\(property.typeName)>(\"\(property.dynamoName)\")"
        }.joined(separator: "\n")

        let accessorDecls = properties.map { property in
            "    \(accessLevel)static var $\(property.swiftName): Attribute<\(property.typeName)> { Attributes.\(property.swiftName) }"
        }.joined(separator: "\n")

        let columnDecls = properties.map { property in
            "        \(accessLevel)let \(property.swiftName) = Attribute<\(property.typeName)>(\"\(property.dynamoName)\")"
        }.joined(separator: "\n")

        let indexesBlock: String
        if indexes.isEmpty {
            indexesBlock = ""
        } else {
            let indexLines = indexes.map { index in
                let indexSortKeyExpr = index.sortKey.map { "\"\($0)\"" } ?? "nil"
                return "        \(accessLevel)static let \(index.swiftName) = Index<\(typeName)>(name: \"\(index.swiftName)\", partitionKey: \"\(index.partitionKey)\", sortKey: \(indexSortKeyExpr))"
            }.joined(separator: "\n")
            indexesBlock = """


                \(accessLevel)enum Indexes {
            \(indexLines)
                }
            """
        }

        let source = """
        extension \(typeName): DynamoModel {
            \(accessLevel)static let _table = TableMetadata(name: "\(tableName)", partitionKey: "\(resolvedPartitionKey)", sortKey: \(sortKeyExpr))

            \(accessLevel)enum Attributes {
        \(attributeDecls)
            }

            \(accessLevel)struct Columns: Sendable {
        \(columnDecls)
            }

            \(accessLevel)static let columns = Columns()\(indexesBlock)

        \(accessorDecls)
        }
        """

        let sourceFile = Parser.parse(source: source)
        guard let extensionDecl = sourceFile.statements.first?.item.as(ExtensionDeclSyntax.self) else {
            throw DiagnosticError("Failed to generate extension")
        }

        return [extensionDecl]
    }
}

// MARK: - Error

struct DiagnosticError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        self.description = message
    }
}
