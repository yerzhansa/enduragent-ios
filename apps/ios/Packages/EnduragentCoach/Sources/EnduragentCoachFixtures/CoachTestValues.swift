import EnduragentCoach
import Foundation

package let testModel = ModelID(rawValue: "test/coach-model")
package let testKey = "sk-or-test-credits-key"
package let testAccess = ResolvedAccess(
	credential: ProviderCredential(secret: testKey, method: .credits), model: testModel)

package let testAthlete: IntervalsAthleteID = {
	guard let athlete = IntervalsAthleteID(rawValue: "i1001") else {
		fatalError("i1001 is not an intervals.icu athlete identifier")
	}
	return athlete
}()

package let testConnection = IntervalsConnection(
	id: ConnectionID(), credential: .apiKey("icu-test-key"), selection: .keyOwner,
	resolvedAthlete: testAthlete)

package let testDisplayLocale: DisplayLocaleResolver = { preference in
	DisplayLocale(
		preference: preference, preferredLanguages: ["en"],
		regionalConventions: Locale(identifier: "en_US"))
}

package func fixedUlid(_ offset: Int) -> ULID {
	let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
	let prefix = ULID.generate(at: Date(timeIntervalSince1970: 899_164_800)).rawValue.prefix(10)
	var suffix = ""
	var remaining = offset
	for _ in 0..<16 {
		suffix = String(alphabet[remaining % 32]) + suffix
		remaining /= 32
	}
	guard let ulid = ULID(rawValue: prefix + suffix) else {
		preconditionFailure("fixed ulid is well formed")
	}
	return ulid
}

package func testRequest(
	_ messages: [WireMessage], tools: [ToolSchema] = [], deadline: Duration = .seconds(600),
	attempt: AttemptID = AttemptID(ulid: fixedUlid(900))
) -> CompletionRequest {
	CompletionRequest(
		access: testAccess, attempt: attempt, charge: .chatAttempt, messages: messages,
		tools: tools, deadline: deadline)
}

package func collect(_ stream: AsyncThrowingStream<TransportEvent, Error>) async throws
	-> [TransportEvent]
{
	var events: [TransportEvent] = []
	for try await event in stream {
		events.append(event)
	}
	return events
}

package func draft(_ text: String) -> Draft {
	Draft(id: DraftID(), text: text)
}

package func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}
