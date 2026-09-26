import Foundation

enum MessageLanguage {
	static func detect(_ text: String) -> LanguageTag? {
		let sample = clean(text)
		if matches(/\p{Script=Hangul}/, sample) { return .ko }
		if matches(/\p{Script=Hiragana}|\p{Script=Katakana}/, sample) { return .ja }
		if matches(/\p{Script=Han}/, sample) {
			return matches(/[體訓練這個們時學車騎鐘週強級區間]/, sample) ? .zhHant : .zhHans
		}
		let tokens = uniqueLatinTokens(sample)
		if tokens.count < 3 { return nil }
		let scores = profiles.compactMap {
			profile -> (language: LanguageTag, score: Int, matches: Int)? in
			var score = 0
			var matchCount = 0
			for token in tokens where profile.words.contains(token) {
				matchCount += 1
				let shared = profiles.filter { $0.words.contains(token) }.count
				score += shared == 1 ? 3 : 1
			}
			if let marker = diacriticPattern(profile.language), matches(marker, sample) {
				score += 2
			}
			return (profile.language, score, matchCount)
		}
		.sorted { $0.score > $1.score }
		guard let best = scores.first else { return nil }
		let second = scores.dropFirst().first
		if best.matches < 3 || best.score < 6 || best.score - (second?.score ?? 0) < 3 {
			return nil
		}
		if best.language == .ptPT,
			tokens.contains("você")
				|| tokens.contains("vocês")
				|| matches(/treino de hoje|\b(?:celular|legal|pedalando)\b/, sample)
		{
			return .ptBR
		}
		return best.language
	}

	static func clean(_ text: String) -> String {
		var stripped = replace(/^\s*(?:\/[\w-]+(?:@[\w-]+)?(?:\s+|$))+/, in: text, with: "")
		stripped = replace(/```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)/, in: stripped, with: " ")
		stripped = replace(/(?i)(?:https?:\/\/|www\.)\S+/, in: stripped, with: " ")
		stripped = replace(/\p{N}+/, in: stripped, with: " ")
		var sample = ""
		var count = 0
		for scalar in stripped.unicodeScalars {
			if count == 512 { break }
			sample.unicodeScalars.append(scalar)
			count += 1
		}
		return sample.precomposedStringWithCanonicalMapping.lowercased()
	}

	static func uniqueLatinTokens(_ sample: String) -> Set<String> {
		let regex = /[\p{Script=Latin}]+(?:['’][\p{Script=Latin}]+)?/
		var tokens: Set<String> = []
		for match in sample.matches(of: regex) {
			tokens.insert(String(match.output))
		}
		return tokens
	}

	static let profiles: [(language: LanguageTag, words: Set<String>)] = [
		(
			.en,
			words(
				"the and of to in is that for it with as was on be this have from or by but not are my can should would how what after before today tomorrow yesterday ride training feel legs recovery easy week during want need more than also a an i me we you"
			)
		),
		(
			.es,
			words(
				"el la los las de del y en que para por con una un es mi mis al se no me como pero más hoy mañana ayer después antes entrenamiento bicicleta piernas puedo debo quiero hacer durante esta este semana tengo siento estoy suave recuperación"
			)
		),
		(
			.fr,
			words(
				"le la les de des du et en que pour avec une un est mon mes au aux je ne pas sur mais plus aujourd'hui demain hier après avant entraînement vélo jambes peux dois voudrais faire pendant cette ce semaine suis ai mes récupération sortie"
			)
		),
		(
			.it,
			words(
				"il lo la gli le di del della e che per con una un è mio mia al non mi come ma più oggi domani ieri dopo prima allenamento bicicletta gambe posso devo vorrei fare durante questa questo settimana sono ho sento recupero uscita"
			)
		),
		(
			.de,
			words(
				"der die das den dem des und in zu ist dass für mit ein eine mein meine am auf ich nicht mir wie aber mehr heute morgen gestern nach vor training fahrrad beine kann soll möchte machen während diese dieser woche habe fühle erholung fahrt"
			)
		),
		(
			.nl,
			words(
				"de het een en van te dat voor met is mijn op ik niet me hoe maar meer vandaag morgen gisteren na vóór training fiets benen kan moet wil doen tijdens deze dit week heb voel herstel rit zijn als om nog graag rustig omdat"
			)
		),
		(
			.da,
			words(
				"den det de en et og af at er for med min mine på jeg ikke mig hvordan men mere i dag morgen efter før træning cykel ben kan skal vil gøre under denne dette uge har føler restitution tur var som til gerne rolig fordi også træt træne trætte roligt kørt"
			)
		),
		(
			.sv,
			words(
				"den det de en ett och av att är för med min mina på jag inte mig hur men mer idag imorgon igår efter före träning cykel ben kan ska vill göra under denna detta vecka har känner återhämtning tur var som till gärna lugn eftersom också trött"
			)
		),
		(
			.nb,
			words(
				"den det de en et og av at er for med min mine på jeg ikke meg hvordan men mer i dag morgen etter før trening sykkel bein kan skal vil gjøre under denne dette uke har føler restitusjon tur var som til gjerne rolig fordi også sliten trene slitne syklet kjørt"
			)
		),
		(
			.fi,
			words(
				"ja on ei että se kun jos niin kuin mutta tai sekä minun olen oli ovat kanssa tänään huomenna eilen jälkeen ennen harjoitus pyörä jalat voin pitäisi haluan tehdä aikana tämä viikko minulla tuntuu palautuminen lenkki miten voinko paljon vielä nyt jotta olisi olivat haluaisin"
			)
		),
		(
			.ptPT,
			words(
				"o a os as de do da dos das e em que para por com uma um é meu minha meus minhas ao não me como mas mais hoje amanhã ontem depois antes treino bicicleta pernas posso devo quero fazer durante esta este semana tenho sinto estou recuperação pedalada"
			)
		),
		(
			.pl,
			words(
				"i w na z do że nie to jest się jak ale po przed dla czy mój moje mam jestem dzisiaj jutro wczoraj trening rower nogi mogę powinien chcę zrobić podczas ten ta tydzień czuję regeneracja jazda bardzo jeszcze ponieważ żeby oraz był były chciałbym odpoczynek"
			)
		),
	]

	static func diacriticPattern(_ tag: LanguageTag) -> (any RegexComponent)? {
		switch tag {
		case .es: /[ñ¿¡]/
		case .fr: /[œç]|[àâêîôû]/
		case .it: /[ìòù]/
		case .de: /[ßü]/
		case .da: /[æø]/
		case .sv: /[äö]/
		case .nb: /[æø]/
		case .fi: /[äö]/
		case .ptPT: /[ãõç]/
		case .pl: /[ąćęłńśźż]/
		default: nil
		}
	}

	static func words(_ list: String) -> Set<String> {
		Set(list.split(separator: " ").map(String.init))
	}

	static func matches(_ pattern: any RegexComponent, _ text: String) -> Bool {
		text.contains(pattern)
	}

	static func replace(
		_ pattern: some RegexComponent,
		in text: String,
		with template: String
	) -> String {
		text.replacing(pattern, with: template)
	}
}
