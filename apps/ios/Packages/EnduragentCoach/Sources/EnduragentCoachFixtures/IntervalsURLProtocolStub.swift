import Foundation
import Synchronization

package class IntervalsURLProtocolStub: URLProtocol, @unchecked Sendable {
	package typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

	private struct Recording: Sendable {
		var lastRequest: URLRequest?
		var lastBody: Data?
		var handler: Handler?
	}

	private static let recordings = Mutex<[ObjectIdentifier: Recording]>([:])

	private class var recording: Recording {
		recordings.withLock { $0[ObjectIdentifier(self)] ?? Recording() }
	}

	package class var lastRequest: URLRequest? { recording.lastRequest }
	package class var lastBody: Data? { recording.lastBody }
	package class var handler: Handler? {
		get { recording.handler }
		set {
			let scope = ObjectIdentifier(self)
			recordings.withLock { $0[scope, default: Recording()].handler = newValue }
		}
	}

	package class func reset() {
		let scope = ObjectIdentifier(self)
		recordings.withLock { $0[scope] = nil }
	}

	override package class func canInit(with request: URLRequest) -> Bool { true }
	override package class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override package func startLoading() {
		let scope = ObjectIdentifier(type(of: self))
		let seen = request
		let body = httpBody(from: seen)
		let handler = Self.recordings.withLock { recordings in
			recordings[scope, default: Recording()].lastRequest = seen
			recordings[scope, default: Recording()].lastBody = body
			return recordings[scope]?.handler
		}
		do {
			let (status, data) = try handler?(seen) ?? (500, Data())
			guard let url = seen.url,
				let response = HTTPURLResponse(
					url: url, statusCode: status, httpVersion: "HTTP/1.1",
					headerFields: ["Content-Type": "application/json"])
			else {
				throw URLError(.badURL)
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override package func stopLoading() {}
}

package final class SeedAccountURLProtocolStub: IntervalsURLProtocolStub, @unchecked Sendable {}

package func httpBody(from request: URLRequest) -> Data? {
	if let body = request.httpBody {
		return body
	}
	guard let stream = request.httpBodyStream else {
		return nil
	}
	stream.open()
	defer { stream.close() }
	let bufferSize = 1024
	let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
	defer { buffer.deallocate() }
	var data = Data()
	while stream.hasBytesAvailable {
		let read = stream.read(buffer, maxLength: bufferSize)
		if read <= 0 {
			break
		}
		data.append(buffer, count: read)
	}
	return data
}
