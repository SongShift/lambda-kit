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
        // Must be attached to a struct
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticError("@Table can only be applied to structs")
        }

        let typeName = type.trimmedDescription

        // Extract table name from @Table("tableName"), or fall back to the struct's name.
        let tableName: String
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self),
           let firstArgument = arguments.first {
            guard let stringLiteral = firstArgument.expression.as(StringLiteralExprSyntax.self),
                  let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
            else {
                throw DiagnosticError("@Table name must be a string literal")
            }
            tableName = segment.content.text
        } else {
            tableName = typeName
        }

        // Collect property metadata
        var partitionKey: (name: String, typeName: String)?
        var sortKey: (name: String, typeName: String)?
        var properties:
            [(swiftName: String, dynamoName: String, typeName: String, representation: String?)] =
                []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation?.type
            else { continue }

            let swiftName = pattern.identifier.text
            let propertyType = typeAnnotation.trimmedDescription

            // Check for @Attribute("customName")
            var dynamoName = swiftName
            var hasAttributeAnnotation = false
            for attribute in varDecl.attributes {
                if let attributeSyntax = attribute.as(AttributeSyntax.self),
                   attributeSyntax.attributeName.trimmedDescription == "Attribute",
                   let arguments = attributeSyntax.arguments?.as(LabeledExprListSyntax.self),
                   let argument = arguments.first,
                   let literal = argument.expression.as(StringLiteralExprSyntax.self),
                   let segment = literal.segments.first?.as(StringSegmentSyntax.self) {
                    dynamoName = segment.content.text
                    hasAttributeAnnotation = true
                }
            }

            // Check for @ExpressionValue(as: SomeRepresentation.self)
            var representation: String?
            for attribute in varDecl.attributes {
                guard let attributeSyntax = attribute.as(AttributeSyntax.self),
                      attributeSyntax.attributeName.trimmedDescription == "ExpressionValue",
                      let arguments = attributeSyntax.arguments?.as(LabeledExprListSyntax.self),
                      let argument = arguments.first(where: { $0.label?.text == "as" })
                else { continue }
                // The argument is a metatype expression like `Rep<T>.self`;
                // strip the `.self` to get the representation type name.
                if let memberAccess = argument.expression.as(MemberAccessExprSyntax.self),
                   memberAccess.declName.baseName.tokenKind == .keyword(.`self`),
                   let base = memberAccess.base {
                    representation = base.trimmedDescription
                } else {
                    throw DiagnosticError("@ExpressionValue(as:) argument must be a metatype literal like `MyRepresentation.self`")
                }
            }

            // Check for @PartitionKey
            let isPartitionKey = varDecl.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "PartitionKey"
            }
            if isPartitionKey {
                partitionKey = (name: dynamoName, typeName: propertyType)
            }

            // Check for @SortKey
            let isSortKey = varDecl.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "SortKey"
            }
            if isSortKey {
                sortKey = (name: dynamoName, typeName: propertyType)
            }

            // Skip computed properties unless explicitly tagged as a key or attribute.
            // Incidental computed properties shouldn't pollute the Attribute namespace
            if let accessors = binding.accessorBlock {
                let hasGetter = accessors.accessors.description.contains("get")
                let isExplicitlyTagged = isPartitionKey || isSortKey || hasAttributeAnnotation
                if hasGetter && !isExplicitlyTagged { continue }
            }

            // Key values travel through `DynamoEncodable` in the generated
            // get/update/delete factories; a representation would be ignored.
            if representation != nil, isPartitionKey || isSortKey {
                throw DiagnosticError("@ExpressionValue(as:) cannot be combined with @PartitionKey or @SortKey")
            }

            properties.append((
                swiftName: swiftName,
                dynamoName: dynamoName,
                typeName: propertyType,
                representation: representation
            ))
        }

        guard let partitionKey else {
            throw DiagnosticError("@Table struct must have exactly one @PartitionKey property")
        }

        // Each key records its DynamoDB scalar type alongside its wire name;
        // the type comes from the property the key name resolves to.
        let typesByWireName = Dictionary(
            properties.map { ($0.dynamoName, $0.typeName) },
            uniquingKeysWith: { first, _ in first }
        )

        // Collect sibling @Index annotations on the struct. The
        // single-attribute form (partitionKey:/sortKey:) and the
        // multi-attribute form (partitionKeys:/sortKeys:) both normalize to
        // key-name arrays here.
        let indexes: [(wireName: String, partitionKeys: [String], sortKeys: [String])] =
            try structDecl.attributes.compactMap { element in
                guard let attributeSyntax = element.as(AttributeSyntax.self),
                      attributeSyntax.attributeName.trimmedDescription == "Index",
                      let arguments = attributeSyntax.arguments?.as(LabeledExprListSyntax.self)
                else { return nil }

                var indexName: String?
                var partitionKeys: [String] = []
                var sortKeys: [String] = []

                for argument in arguments {
                    switch argument.label?.text {
                    case nil:
                        indexName = stringLiteralValue(argument.expression)
                    case "partitionKey":
                        partitionKeys = stringLiteralValue(argument.expression).map { [$0] } ?? []
                    case "sortKey":
                        sortKeys = stringLiteralValue(argument.expression).map { [$0] } ?? []
                    case "partitionKeys":
                        partitionKeys = try stringLiteralArray(argument.expression, label: "partitionKeys")
                    case "sortKeys":
                        sortKeys = try stringLiteralArray(argument.expression, label: "sortKeys")
                    default:
                        break
                    }
                }

                guard let indexName, !partitionKeys.isEmpty else { return nil }
                return (wireName: indexName, partitionKeys: partitionKeys, sortKeys: sortKeys)
            }

        // Detect access level: match the struct's visibility
        let isPublic = structDecl.modifiers.contains {
            $0.name.tokenKind == .keyword(.public)
        }
        let accessLevel = isPublic ? "public " : ""

        // Build the extension source
        let partitionKeyAttributeExpr = try keyAttributeExpr(
            name: partitionKey.name, typeName: partitionKey.typeName, context: "@PartitionKey")
        let sortKeyExpr = try sortKey.map {
            try keyAttributeExpr(name: $0.name, typeName: $0.typeName, context: "@SortKey")
        } ?? "nil"

        // `@ExpressionValue(as:)` properties surface as `RepresentedAttribute<Rep>`
        // instead of `Attribute<Type>`, so their DSL ops encode through the
        // declared representation.
        func attributeType(_ property: (
            swiftName: String, dynamoName: String, typeName: String, representation: String?
        )) -> String {
            if let representation = property.representation {
                return "RepresentedAttribute<\(representation)>"
            }
            return "Attribute<\(property.typeName)>"
        }

        let attributeDecls = properties.map { property in
            "        \(accessLevel)static let \(property.swiftName) = \(attributeType(property))(\"\(property.dynamoName)\")"
        }.joined(separator: "\n")

        let accessorDecls = properties.map { property in
            "    \(accessLevel)static var $\(property.swiftName): \(attributeType(property)) { Attributes.\(property.swiftName) }"
        }.joined(separator: "\n")

        let columnDecls = properties.map { property in
            "        \(accessLevel)let \(property.swiftName) = \(attributeType(property))(\"\(property.dynamoName)\")"
        }.joined(separator: "\n")

        // Key-shaped CRUD factories. The macro knows the table's key shape, so
        // it emits *only* the matching overload, non-throwing, since there's
        // nothing left to validate at runtime. Calling the wrong arity (a
        // sortKey on a partition-only table, or omitting it on a composite one)
        // is a compile error rather than a thrown `PrimaryKeyError`.
        let partitionKeyExpr = "[\"\(partitionKey.name)\": partitionKey.toDynamoValue()]"
        let factoryBlock: String
        if let sortKey {
            let compositeKeyExpr =
                "[\"\(partitionKey.name)\": partitionKey.toDynamoValue(), \"\(sortKey.name)\": sortKey.toDynamoValue()]"
            factoryBlock = """


                \(accessLevel)static func get(partitionKey: some DynamoQueries.DynamoEncodable, sortKey: some DynamoQueries.DynamoEncodable) -> DynamoQueries.GetItemInput<\(typeName)> {
                    DynamoQueries.GetItemInput(tableName: _table.name, key: \(compositeKeyExpr))
                }

                \(accessLevel)static func update(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    sortKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.UpdateBuilder _ build: (Columns) throws -> [DynamoQueries.UpdateAction],
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in [] }
                ) rethrows -> DynamoQueries.UpdateInput<\(typeName)> {
                    DynamoQueries.UpdateInputBuilder.build(for: \(typeName).self, key: \(compositeKeyExpr), actions: try build(columns), condition: condition(columns))
                }

                \(accessLevel)static func delete(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    sortKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in [] }
                ) -> DynamoQueries.DeleteItemInput<\(typeName)> {
                    DynamoQueries.DeleteItemInputBuilder.build(for: \(typeName).self, key: \(compositeKeyExpr), condition: condition(columns))
                }
            """
        } else {
            factoryBlock = """


                \(accessLevel)static func get(partitionKey: some DynamoQueries.DynamoEncodable) -> DynamoQueries.GetItemInput<\(typeName)> {
                    DynamoQueries.GetItemInput(tableName: _table.name, key: \(partitionKeyExpr))
                }

                \(accessLevel)static func update(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.UpdateBuilder _ build: (Columns) throws -> [DynamoQueries.UpdateAction],
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in [] }
                ) rethrows -> DynamoQueries.UpdateInput<\(typeName)> {
                    DynamoQueries.UpdateInputBuilder.build(for: \(typeName).self, key: \(partitionKeyExpr), actions: try build(columns), condition: condition(columns))
                }

                \(accessLevel)static func delete(
                    partitionKey: some DynamoQueries.DynamoEncodable,
                    @DynamoQueries.ConditionBuilder where condition: (Columns) -> [DynamoQueries.Expression] = { _ in [] }
                ) -> DynamoQueries.DeleteItemInput<\(typeName)> {
                    DynamoQueries.DeleteItemInputBuilder.build(for: \(typeName).self, key: \(partitionKeyExpr), condition: condition(columns))
                }
            """
        }

        let indexesBlock: String
        if indexes.isEmpty {
            indexesBlock = ""
        } else {
            // DynamoDB index names allow characters Swift identifiers don't
            // ("byEmail-index"); the identifier is camel-cased from the wire
            // name, which is emitted verbatim.
            var identifierToWireName: [String: String] = [:]
            var identifiers: [String] = []
            let indexLines = try indexes.map { index in
                let identifier = try swiftIdentifier(forIndexName: index.wireName)
                if let existing = identifierToWireName[identifier] {
                    throw DiagnosticError(
                        "@Index names \"\(existing)\" and \"\(index.wireName)\" both map to the Swift identifier \"\(identifier)\""
                    )
                }
                identifierToWireName[identifier] = index.wireName
                identifiers.append(identifier)

                guard index.partitionKeys.count <= 4, index.sortKeys.count <= 4 else {
                    throw DiagnosticError(
                        "@Index \"\(index.wireName)\" exceeds DynamoDB's limit of 4 partition-key and 4 sort-key attributes"
                    )
                }

                let context = "@Index \"\(index.wireName)\""
                let partitionExprs = try index.partitionKeys.map {
                    try resolvedKeyAttributeExpr(name: $0, in: typesByWireName, context: context)
                }
                let sortExprs = try index.sortKeys.map {
                    try resolvedKeyAttributeExpr(name: $0, in: typesByWireName, context: context)
                }
                let sortArgument = sortExprs.isEmpty
                    ? "" : ", sortKeys: [\(sortExprs.joined(separator: ", "))]"
                return "        \(accessLevel)static let \(identifier) = Index<\(typeName)>(name: \"\(index.wireName)\", partitionKeys: [\(partitionExprs.joined(separator: ", "))]\(sortArgument))"
            }.joined(separator: "\n")
            let indexList = identifiers.map { "Indexes.\($0)" }.joined(separator: ", ")
            indexesBlock = """


                \(accessLevel)enum Indexes {
            \(indexLines)
                }

                \(accessLevel)static let indexes: [Index<\(typeName)>] = [\(indexList)]
            """
        }

        let source = """
        extension \(typeName): DynamoModel {
            \(accessLevel)static let _table = TableMetadata(name: "\(tableName)", partitionKey: \(partitionKeyAttributeExpr), sortKey: \(sortKeyExpr))

            \(accessLevel)enum Attributes {
        \(attributeDecls)
            }

            \(accessLevel)struct Columns: Sendable {
        \(columnDecls)
            }

            \(accessLevel)static let columns = Columns()\(indexesBlock)\(factoryBlock)

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

// MARK: - Key attributes

/// Extracts a string literal's value, or `nil` for any other expression.
func stringLiteralValue(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
          let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else { return nil }
    return segment.content.text
}

/// Extracts the elements of an array-literal argument like
/// `partitionKeys: ["creatorId", "isDeleted"]`.
func stringLiteralArray(_ expression: ExprSyntax, label: String) throws -> [String] {
    guard let array = expression.as(ArrayExprSyntax.self) else {
        throw DiagnosticError("@Index \(label) must be an array literal of string literals")
    }
    return try array.elements.map { element in
        guard let value = stringLiteralValue(element.expression) else {
            throw DiagnosticError("@Index \(label) must be an array literal of string literals")
        }
        return value
    }
}

/// Renders a `KeyAttribute(...)` expression. The emitted
/// `(Type).dynamoKeyType` defers the scalar type to the property's
/// `DynamoKeyEncodable` conformance. `Bool` gets a friendlier diagnostic here
/// than the missing-conformance error the compiler would otherwise emit at
/// the expansion site.
func keyAttributeExpr(name: String, typeName: String, context: String) throws -> String {
    var scalarBase = typeName
    while scalarBase.hasSuffix("?") || scalarBase.hasSuffix("!") {
        scalarBase = String(scalarBase.dropLast())
    }
    if scalarBase == "Bool" || scalarBase == "Optional<Bool>" {
        throw DiagnosticError(
            "\(context) key \"\(name)\" is Bool, which DynamoDB rejects as a key attribute (keys must be S, N, or B); store the flag as an Int"
        )
    }
    return "KeyAttribute(\"\(name)\", type: (\(typeName)).dynamoKeyType)"
}

/// Resolves an index key by wire name against the model's properties, then
/// renders its `KeyAttribute(...)` expression.
func resolvedKeyAttributeExpr(
    name: String,
    in typesByWireName: [String: String],
    context: String
) throws -> String {
    guard let typeName = typesByWireName[name] else {
        throw DiagnosticError(
            "\(context) references \"\(name)\", which doesn't match any property's DynamoDB attribute name"
        )
    }
    return try keyAttributeExpr(name: name, typeName: typeName, context: context)
}

// MARK: - Index identifiers

/// Camel-cases a DynamoDB index name into a valid Swift identifier:
/// `"byEmail-index"` becomes `byEmailIndex`. Only the generated `Indexes`
/// member is renamed; the wire name is emitted verbatim.
func swiftIdentifier(forIndexName name: String) throws -> String {
    var result = ""
    var uppercaseNext = false
    for character in name {
        if character.isLetter || character.isNumber || character == "_" {
            if uppercaseNext, !result.isEmpty {
                result.append(contentsOf: String(character).uppercased())
            } else {
                result.append(character)
            }
            uppercaseNext = false
        } else {
            uppercaseNext = true
        }
    }
    guard !result.isEmpty else {
        throw DiagnosticError(
            "@Index name \"\(name)\" contains no characters usable in a Swift identifier")
    }
    if result.first!.isNumber {
        result = "_" + result
    }
    return result
}

// MARK: - Error

struct DiagnosticError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        self.description = message
    }
}
