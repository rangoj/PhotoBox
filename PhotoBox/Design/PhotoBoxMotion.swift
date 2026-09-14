import SwiftUI

enum PhotoBoxMotion {
    enum Mode: String {
        case native
        case reduced
    }

    static func transaction(reduceMotion: Bool) -> Transaction? {
        guard reduceMotion else { return nil }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }

    @discardableResult
    static func perform<Result>(
        reduceMotion: Bool,
        recordMode: ((Mode) -> Void)? = nil,
        _ action: () throws -> Result
    ) rethrows -> Result {
        guard let transaction = transaction(reduceMotion: reduceMotion) else {
            recordMode?(.native)
            return try action()
        }

        recordMode?(.reduced)
        return try withTransaction(transaction, action)
    }
}
