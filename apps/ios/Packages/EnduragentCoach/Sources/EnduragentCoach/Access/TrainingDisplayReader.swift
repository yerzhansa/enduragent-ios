import Foundation

struct TrainingDisplayReader: Sendable {
	let training: TrainingService
	let clock: any Clock

	func client(for connection: IntervalsConnection) -> any IntervalsClient {
		training.makeClient(connection.credential, connection.selection, clock)
	}

	func profile(for connection: IntervalsConnection) async -> IntervalsProfileState {
		do {
			let athlete = try await client(for: connection).fetchAthlete()
			guard let id = IntervalsAthleteID(rawValue: athlete.id) else {
				return .failed(.temporarilyUnavailable)
			}
			return .available(
				IntervalsProfile(athleteID: id, name: athlete.name, wellness: .waiting))
		} catch {
			return .failed(TrainingFailure(error))
		}
	}

	func wellness(for connection: IntervalsConnection) async -> IntervalsWellnessState {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		do {
			let days = try await client(for: connection).fetchWellness(oldest: today, newest: today)
			return .available(
				days.first(where: { $0.date == today }).map(IntervalsWellnessResult.day)
					?? .noData(on: today))
		} catch {
			return .failed(
				TrainingFailure(error) == .temporarilyUnavailable
					? .temporarilyUnavailable : .requestRejected)
		}
	}

	func summary(for connection: IntervalsConnection) async -> IntervalsSummary {
		let profile = await profile(for: connection)
		guard case .available(let athlete) = profile else {
			return summary(for: connection, profile: profile)
		}
		return summary(
			for: connection,
			profile: .available(
				IntervalsProfile(
					athleteID: athlete.athleteID, name: athlete.name,
					wellness: await wellness(for: connection))))
	}

	func summary(for connection: IntervalsConnection, profile: IntervalsProfileState)
		-> IntervalsSummary
	{
		IntervalsSummary(
			connectionID: connection.id, keySuffix: connection.credential.keySuffix,
			profile: profile)
	}
}
