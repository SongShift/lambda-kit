/// The set of attribute-type discriminators DynamoDB exposes through the
/// `attribute_type(path, type)` function. Raw values are the on-the-wire
/// codes DynamoDB expects.
///
/// Most schemas have known types, so `attribute_type` is rarely needed. It
/// comes in handy for polymorphic attributes — e.g. a field that holds
/// either a string or a number depending on context — when you want a
/// condition expression to branch on which case is currently stored.
public enum DynamoAttributeType: String, Sendable, Equatable {
    case string = "S"
    case number = "N"
    case binary = "B"
    case bool = "BOOL"
    case null = "NULL"
    case list = "L"
    case map = "M"
    case stringSet = "SS"
    case numberSet = "NS"
    case binarySet = "BS"
}
