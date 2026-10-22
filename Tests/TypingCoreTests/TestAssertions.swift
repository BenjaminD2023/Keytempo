import Testing

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual == expected, Comment(rawValue: message))
}

func checkEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "") {
    #expect(abs(actual - expected) <= accuracy, Comment(rawValue: "\(message) actual=\(actual), expected=\(expected), tolerance=\(accuracy)"))
}

func checkNil<T>(_ value: T?, _ message: String = "") {
    #expect(value == nil, Comment(rawValue: message))
}

func checkTrue(_ value: Bool, _ message: String = "") {
    #expect(value, Comment(rawValue: message))
}

func checkLessThanOrEqual<T: Comparable>(_ actual: T, _ limit: T) {
    #expect(actual <= limit)
}
