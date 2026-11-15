/// The symptom categories supported by HealthKit on iOS 18.
public enum Symptom: String, CaseIterable, Codable, Sendable {
    case abdominalCramps, acne, appetiteChanges, bladderIncontinence, bloating, breastPain
    case chestTightnessOrPain, chills, constipation, coughing, diarrhea, dizziness, drySkin
    case fainting, fatigue, fever, generalizedBodyAche, hairLoss, headache, heartburn, hotFlashes
    case lossOfSmell, lossOfTaste, lowerBackPain, memoryLapse, moodChanges, nausea, nightSweats
    case pelvicPain, rapidPoundingOrFlutteringHeartbeat, runnyNose, shortnessOfBreath, sinusCongestion
    case skippedHeartbeat, sleepChanges, soreThroat, vaginalDryness, vomiting, wheezing
}

public enum SymptomValueFamily: Sendable {
    case severity
    case presence
    case appetite
}

extension Symptom {
    public var healthKitIdentifier: String {
        "HKCategoryTypeIdentifier" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    public var valueFamily: SymptomValueFamily {
        switch self {
        case .appetiteChanges: .appetite
        case .moodChanges, .sleepChanges: .presence
        default: .severity
        }
    }

    public var displayName: String {
        switch self {
        case .abdominalCramps: "Abdominal Cramps"
        case .acne: "Acne"
        case .appetiteChanges: "Appetite Changes"
        case .bladderIncontinence: "Bladder Incontinence"
        case .bloating: "Bloating"
        case .breastPain: "Breast Pain"
        case .chestTightnessOrPain: "Chest Tightness or Pain"
        case .chills: "Chills"
        case .constipation: "Constipation"
        case .coughing: "Coughing"
        case .diarrhea: "Diarrhea"
        case .dizziness: "Dizziness"
        case .drySkin: "Dry Skin"
        case .fainting: "Fainting"
        case .fatigue: "Fatigue"
        case .fever: "Fever"
        case .generalizedBodyAche: "Generalized Body Ache"
        case .hairLoss: "Hair Loss"
        case .headache: "Headache"
        case .heartburn: "Heartburn"
        case .hotFlashes: "Hot Flashes"
        case .lossOfSmell: "Loss of Smell"
        case .lossOfTaste: "Loss of Taste"
        case .lowerBackPain: "Lower Back Pain"
        case .memoryLapse: "Memory Lapse"
        case .moodChanges: "Mood Changes"
        case .nausea: "Nausea"
        case .nightSweats: "Night Sweats"
        case .pelvicPain: "Pelvic Pain"
        case .rapidPoundingOrFlutteringHeartbeat: "Rapid, Pounding, or Fluttering Heartbeat"
        case .runnyNose: "Runny Nose"
        case .shortnessOfBreath: "Shortness of Breath"
        case .sinusCongestion: "Sinus Congestion"
        case .skippedHeartbeat: "Skipped Heartbeat"
        case .sleepChanges: "Sleep Changes"
        case .soreThroat: "Sore Throat"
        case .vaginalDryness: "Vaginal Dryness"
        case .vomiting: "Vomiting"
        case .wheezing: "Wheezing"
        }
    }

    public var symbol: String {
        switch self {
        case .abdominalCramps, .bloating, .constipation, .diarrhea, .nausea, .vomiting: "cross.case"
        case .acne, .drySkin, .hairLoss: "hand.raised"
        case .appetiteChanges: "fork.knife"
        case .bladderIncontinence, .vaginalDryness: "drop"
        case .breastPain, .generalizedBodyAche, .lowerBackPain, .pelvicPain: "figure.stand"
        case .chestTightnessOrPain, .rapidPoundingOrFlutteringHeartbeat, .skippedHeartbeat: "heart"
        case .chills: "snowflake"
        case .coughing, .shortnessOfBreath, .wheezing: "lungs"
        case .dizziness, .fainting: "circle.dotted"
        case .fatigue: "battery.25percent"
        case .fever, .hotFlashes: "thermometer"
        case .headache, .memoryLapse: "brain.head.profile"
        case .heartburn: "flame"
        case .lossOfSmell, .runnyNose, .sinusCongestion: "nose"
        case .lossOfTaste, .soreThroat: "mouth"
        case .moodChanges: "face.smiling"
        case .nightSweats, .sleepChanges: "moon"
        }
    }
}
