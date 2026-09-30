import Foundation
import SQLite3

func restoreRecordStore(_ sql: String, into url: URL) throws {
	var handle: OpaquePointer?
	guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
		throw RecordStoreRestoreFailure(step: "open")
	}
	defer { sqlite3_close(database) }
	var message: UnsafeMutablePointer<CChar>?
	guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
		let detail = message.map { String(cString: $0) } ?? "exec"
		sqlite3_free(message)
		throw RecordStoreRestoreFailure(step: detail)
	}
}

struct RecordStoreRestoreFailure: Error {
	let step: String
}
