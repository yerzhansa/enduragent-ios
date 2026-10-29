import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FeedbackDeliveryTests {
	enum ExpectedAnswer: Sendable {
		case stored
		case answer(AttemptAnswer)
	}

	enum Settled: Sendable, Equatable {
		case received
		case notSent(NotSentReason)
		case notConfirmed

		init(_ outcome: FeedbackOutcome) {
			switch outcome {
			case .received: self = .received
			case .notSent(let reason): self = .notSent(reason)
			case .notConfirmed: self = .notConfirmed
			}
		}
	}

	static let statusTable: [(Int, ExpectedAnswer)] = [
		(200, .answer(.refused(status: 200))),
		(201, .answer(.refused(status: 201))),
		(204, .stored),
		(299, .answer(.refused(status: 299))),
		(300, .answer(.redirected(status: 300))),
		(302, .answer(.redirected(status: 302))),
		(399, .answer(.redirected(status: 399))),
		(400, .answer(.refused(status: 400))),
		(404, .answer(.refused(status: 404))),
		(429, .answer(.limited)),
		(500, .answer(.mayHaveLeft(.serverStatus(500)))),
		(502, .answer(.mayHaveLeft(.serverStatus(502)))),
		(503, .answer(.unavailable)),
		(599, .answer(.mayHaveLeft(.serverStatus(599)))),
	]

	@Test(arguments: statusTable)
	func answerOfAStatus(_ status: Int, _ expected: ExpectedAnswer) {
		let answer = AttemptAnswer(status: status)
		switch expected {
		case .stored: #expect(Self.isStored(answer))
		case .answer(let expected): #expect(answer == expected)
		}
	}

	static let neverLeftCodes: [URLError.Code] = [
		.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
		.dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
		.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
		.serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
		.appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
	]

	@Test(arguments: neverLeftCodes)
	func aCodeBeforeTheConnectionNeverLeft(_ code: URLError.Code) {
		#expect(Leg.of(code) == .neverLeft)
	}

	static let mayHaveLeftCodes: [URLError.Code] = [
		.timedOut, .networkConnectionLost, .badServerResponse, .cannotParseResponse, .cancelled,
		.backgroundSessionWasDisconnected, .cannotDecodeRawData, .zeroByteResource,
		URLError.Code(rawValue: -4_242),
	]

	@Test(arguments: mayHaveLeftCodes)
	func aListedOrUnlistedLaterCodeMayHaveLeft(_ code: URLError.Code) {
		#expect(Leg.of(code) == .mayHaveLeft)
	}

	@Test func answerOfAThrownError() {
		let cocoa = CocoaError(.fileReadUnknown)
		let thrown: [(any Error, AttemptAnswer)] = [
			(URLError(.cannotFindHost), .neverLeft(.cannotFindHost)),
			(URLError(.timedOut), .mayHaveLeft(.transport(.timedOut))),
			(cocoa, .mayHaveLeft(.otherError(FailureCode(cocoa)))),
		]
		for (error, expected) in thrown {
			let answer = AttemptAnswer(error: error)
			#expect(answer == expected)
			#expect(answer.retried)
		}
	}

	static let retriedTable: [(AttemptAnswer, Bool)] = [
		(AttemptAnswer(status: 204), false),
		(.unavailable, true),
		(.limited, false),
		(.refused(status: 400), false),
		(.redirected(status: 302), true),
		(.neverLeft(.notConnectedToInternet), true),
		(.mayHaveLeft(.serverStatus(502)), false),
		(.mayHaveLeft(.transport(.networkConnectionLost)), true),
		(.mayHaveLeft(.otherError(.cocoa(256))), true),
	]

	@Test(arguments: retriedTable)
	func retriedFollowsNpmsRetrySet(_ answer: AttemptAnswer, _ retried: Bool) {
		#expect(answer.retried == retried)
		#expect(FeedbackDelivery.shouldRetry(after: [answer]) == retried)
	}

	@Test func shouldRetryStopsAtTwoAnswers() {
		let answers = Self.retriedTable.map(\.0)
		for first in answers {
			for second in answers {
				#expect(!FeedbackDelivery.shouldRetry(after: [first, second]))
			}
		}
	}

	static let answerMeanings: [(AttemptAnswer, Settled)] = [
		(AttemptAnswer(status: 204), .received),
		(.unavailable, .notSent(.busy)),
		(.limited, .notSent(.busy)),
		(.refused(status: 400), .notSent(.refused)),
		(.refused(status: 200), .notSent(.refused)),
		(.redirected(status: 302), .notSent(.refused)),
		(.neverLeft(.cannotFindHost), .notSent(.noConnection)),
		(.mayHaveLeft(.serverStatus(502)), .notConfirmed),
		(.mayHaveLeft(.transport(.timedOut)), .notConfirmed),
		(.mayHaveLeft(.otherError(.cocoa(256))), .notConfirmed),
	]

	static let priors: [KeptPhase?] = [
		nil, .ready, .sending, .notSent(.noConnection), .notSent(.busy), .notSent(.refused),
		.notSent(.stopped), .notConfirmed,
	]

	@Test(arguments: priors)
	func settleFoldsEveryOneAndTwoAnswerList(_ prior: KeptPhase?) throws {
		let ones = Self.answerMeanings.map { [$0] }
		let twos = Self.answerMeanings.flatMap { first in
			Self.answerMeanings.map { [first, $0] }
		}
		for list in ones + twos {
			let newest = try #require(list.last).1
			let expected: Settled =
				if list.contains(where: { $0.1 == .received }) {
					.received
				} else if prior == .sending || prior == .notConfirmed
					|| list.contains(where: { $0.1 == .notConfirmed })
				{
					.notConfirmed
				} else {
					newest
				}
			let outcome = FeedbackDelivery.settle(prior: prior, answers: list.map(\.0))
			#expect(Settled(outcome) == expected)
		}
	}

	static let namedFolds: [(KeptPhase?, [AttemptAnswer], Settled)] = [
		(
			nil,
			[
				.mayHaveLeft(.transport(.networkConnectionLost)),
				.mayHaveLeft(.transport(.timedOut)),
			],
			.notConfirmed
		),
		(.notConfirmed, [AttemptAnswer(status: 204)], .received),
		(nil, [.redirected(status: 302)], .notSent(.refused)),
		(nil, [.redirected(status: 302), .redirected(status: 302)], .notSent(.refused)),
		(nil, [.neverLeft(.cannotFindHost), .unavailable], .notSent(.busy)),
		(nil, [.unavailable, .neverLeft(.cannotFindHost)], .notSent(.noConnection)),
		(nil, [.mayHaveLeft(.transport(.timedOut)), .neverLeft(.cannotFindHost)], .notConfirmed),
		(.sending, [.neverLeft(.notConnectedToInternet)], .notConfirmed),
		(.notSent(.busy), [.neverLeft(.notConnectedToInternet)], .notSent(.noConnection)),
		(nil, [], .notConfirmed),
	]

	@Test(arguments: namedFolds)
	func aNamedFoldSettlesAsWritten(
		_ prior: KeptPhase?, _ answers: [AttemptAnswer], _ expected: Settled
	) {
		#expect(Settled(FeedbackDelivery.settle(prior: prior, answers: answers)) == expected)
	}

	static let relaunches: [(KeptPhase, KeptPhase)] = [
		(.ready, .notSent(.stopped)),
		(.sending, .notConfirmed),
		(.notSent(.noConnection), .notSent(.noConnection)),
		(.notSent(.busy), .notSent(.busy)),
		(.notSent(.refused), .notSent(.refused)),
		(.notSent(.stopped), .notSent(.stopped)),
		(.notConfirmed, .notConfirmed),
	]

	@Test(arguments: relaunches)
	func aRelaunchSettlesAnInterruptedSend(_ phase: KeptPhase, _ settled: KeptPhase) {
		#expect(phase.afterRelaunch == settled)
	}

	@Test(arguments: relaunches.map(\.0))
	func aKeptNoteDecodesBackEqual(_ phase: KeptPhase) throws {
		let text = try FeedbackText(validating: "the lap table is cut off 😀")
		let kept = KeptNote(note: .first(text), phase: phase)
		let encoded = try JSONEncoder().encode(kept)
		#expect(try JSONDecoder().decode(KeptNote.self, from: encoded) == kept)
	}

	private static func isStored(_ answer: AttemptAnswer) -> Bool {
		if case .stored = answer { true } else { false }
	}
}
