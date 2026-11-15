import AppIntents
import Foundation

struct OpenMealCameraIntent: OpenIntent {
    static let title: LocalizedStringResource = "Capture Meal"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Destination")
    var target: MealCameraDestination

    init() {
        target = .camera
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !BITELENS_CONTROL_EXTENSION
        CameraControlLaunch.shared.requestCamera()
        #endif
        return .result()
    }
}

enum MealCameraDestination: String, AppEnum {
    case camera

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "BiteLens screen")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .camera: "Meal camera"
    ]
}
