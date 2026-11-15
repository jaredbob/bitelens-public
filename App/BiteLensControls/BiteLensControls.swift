import SwiftUI
import WidgetKit

@main
struct BiteLensControls: WidgetBundle {
    var body: some Widget {
        MealCameraControl()
    }
}

struct MealCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.example.BiteLens.capture-meal") {
            ControlWidgetButton(action: OpenMealCameraIntent()) {
                Label("Capture Meal", image: .biteLensCapture)
            }
        }
        .displayName("Capture Meal")
        .description("Open the BiteLens meal camera.")
    }
}
