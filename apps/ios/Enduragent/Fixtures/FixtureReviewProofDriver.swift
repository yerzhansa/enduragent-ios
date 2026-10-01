#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	actor FixtureReviewProofDriver {
		private var pending = true
		private var presented: ReviewRef?

		func didPresent(_ ref: ReviewRef) {
			presented = ref
		}

		func refreshIfReady(
			_ snapshot: ChatSnapshot?, coach: Coach, records: RecordFaults
		) async {
			guard pending, let snapshot, let review = snapshot.review,
				review.ref == presented, review.controls != .none,
				snapshot.turns.allSatisfy({ $0.state.isSettled })
			else { return }
			pending = false
			records.failNextReviewRead()
			_ = await coach.decide(.presented(review.ref), in: snapshot.chat)
		}
	}
#endif
