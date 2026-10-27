import Foundation

enum TerminalDrawerLayoutRegressionTests {
    static func runAll() throws {
        let layout = TerminalDrawerLayout.self
        try expect(layout.height(requested: 220, availableHeight: 500) == 220)
        try expect(layout.height(requested: -500, availableHeight: 500) == 180)
        try expect(layout.height(requested: 9999, availableHeight: 500) == 310)
        // A fixed drag anchor uses total translation exactly once on each update.
        try expect(layout.draggedHeight(start: 220, translation: -20, availableHeight: 600) == 240)
        try expect(layout.draggedHeight(start: 220, translation: -40, availableHeight: 600) == 260)
        try expect(layout.draggedHeight(start: 220, translation: 40, availableHeight: 600) == 180)
        try expect(layout.draggedHeight(start: 220, translation: -500, availableHeight: 400) == 210)
        // Shrink clamps the displayed height, without mutating the retained preference.
        let preferred: CGFloat = 360
        try expect(layout.height(requested: preferred, availableHeight: 400) == 210)
        try expect(layout.height(requested: preferred, availableHeight: 700) == preferred)
        for available: CGFloat in [0, 5, 10, 80, 200, 369, 370, 400, 1000] {
            let result = layout.height(requested: 9999, availableHeight: available)
            try expect(result >= 0 && result.isFinite)
            try expect(result <= max(0, available - layout.dividerHeight))
            if available >= layout.minimumHeight + layout.minimumFileHeight + layout.dividerHeight {
                try expect(result >= layout.minimumHeight)
                try expect(available - layout.dividerHeight - result >= layout.minimumFileHeight)
            }
        }
        try expect(layout.height(requested: .nan, availableHeight: 500) == 220)
        try expect(layout.height(requested: .infinity, availableHeight: 500) == 220)
        try expect(layout.height(requested: 220, availableHeight: .nan) == 0)
        try expect(layout.draggedHeight(start: 220, translation: .nan, availableHeight: 500) == 220)
        print("PASS bounded terminal drawer geometry and anchored drag regressions")
    }
}
