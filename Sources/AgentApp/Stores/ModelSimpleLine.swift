import Foundation

/// The Overview model section's top part (P21b item 1): "Model: <name> · <supplier>", whether the plain picker shows,
/// its title, and at most one plain sentence. Pure; read from `ModelPickerModel` without changing how a model is applied.
/// Everything else the section knows (source, notes, supplier caption, roles, last turn) is folded under Advanced.
struct ModelSimpleLine: Equatable, Sendable {
    let line: String
    let showsPicker: Bool
    let pickerTitle: String
    let status: String?
    let isWarning: Bool

    init(picker: ModelPickerModel, isRefreshing: Bool, error: String?) {
        if let model = picker.currentModel { line = InspectorCopy.modelLine(model, supplier: picker.currentSupplier) }
        else { line = isRefreshing || picker.isLoading ? InspectorCopy.modelChecking : InspectorCopy.modelNotReported }
        showsPicker = picker.showsMenu
        pickerTitle = picker.isSwitching ? InspectorCopy.switching : InspectorCopy.changeModel
        let warns = error != nil || picker.notes.contains { $0.isWarning }
        isWarning = warns
        if warns { status = InspectorCopy.modelAttention }
        else if picker.isLoading { status = InspectorCopy.modelsLoading }
        else if !picker.showsMenu { status = InspectorCopy.modelsNotListed }
        else {
            switch picker.blocked {
            case .noChat: status = InspectorCopy.modelSendFirst
            case .notYet, .readOnly: status = InspectorCopy.modelFixed
            case .switching, nil: status = nil
            }
        }
    }
}
