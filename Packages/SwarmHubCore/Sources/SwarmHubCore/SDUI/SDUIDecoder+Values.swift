import Foundation

/// Text, bindings, predicates, actions and form fields. Same order of checks as `scripts/release/ui_reference.py`.
extension SDUIReader {
    /// A literal string, or `{"bind": path}`.
    func text(_ value: JCS.Value?) throws -> SDUIText {
        if case .string(let literal)? = value {
            try self.literal(literal)
            return .literal(literal)
        }
        return .binding(try bindingObject(value))
    }

    func optionalText(_ value: JCS.Value?) throws -> SDUIText? {
        guard let value else { return nil }
        return try text(value)
    }

    func bindingObject(_ value: JCS.Value?) throws -> SDUIBinding {
        guard case .object(let members)? = value, Set(members.keys) == ["bind"],
              case .string(let path)? = members["bind"] else { throw invalid }
        return try binding(path)
    }

    func binding(_ path: String) throws -> SDUIBinding {
        try sduiRequire(matches(path, SDUICatalog.bindingPattern), "invalid_binding")
        let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        try sduiRequire(SDUICatalog.bindingRoots.contains(segments[0]), "invalid_binding")
        try sduiRequire(!segments.contains(where: SDUICatalog.deniedSegment), "denied_binding")
        return SDUIBinding(path: path)
    }

    func literal(_ text: String) throws {
        try sduiRequire(text.utf8.count <= policy.limits.maxStringBytes, "string_too_long")
        try sduiRequire(!text.unicodeScalars.contains {
            ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127
        }, "invalid_text")
    }

    /// Markdown subset only: no links, images or HTML tags. URLs reach the user only through `open_url`.
    func markup(_ text: String) throws {
        let bytes = Array(text.utf8)
        var tag = false
        for index in bytes.indices.dropLast() where bytes[index] == 0x3C {
            let next = bytes[index + 1]
            if (0x41...0x5A).contains(next) || (0x61...0x7A).contains(next) || [0x2F, 0x21, 0x3F].contains(next) {
                tag = true
                break
            }
        }
        try sduiRequire(!SDUICatalog.containsBytes(bytes, Array("](".utf8))
                        && !SDUICatalog.containsBytes(bytes, Array("![".utf8)) && !tag, "markup_not_allowed")
    }

    func predicate(_ value: JCS.Value?) throws -> SDUIPredicate {
        let refused = SDUIRefusal(reason: "invalid_predicate")
        guard case .object(let members)? = value, members.count == 1, let only = members.first,
              ["exists", "missing", "equals"].contains(only.key), case .object(let fields) = only.value else { throw refused }
        let op = only.key
        let expected: Set<String> = op == "equals" ? ["bind", "value"] : ["bind"]
        guard Set(fields.keys) == expected, case .string(let path)? = fields["bind"] else { throw refused }
        let bound = try binding(path)
        switch op {
        case "exists": return .exists(bound)
        case "missing": return .missing(bound)
        default:
            switch fields["value"] {
            case .bool(let flag)?: return .equals(bound, .bool(flag))
            case .integer(let number)?: return .equals(bound, .integer(number))
            case .string(let text)?:
                try literal(text)
                return .equals(bound, .string(text))
            default: throw refused
            }
        }
    }

    func action(_ value: JCS.Value?, submit: Bool, inFlow: Bool) throws -> SDUIAction {
        let m = try object(value)
        guard case .string(let name)? = m["command"] else { throw invalid }
        try sduiRequire(!SDUICatalog.deniedSurface(name), "denied_route")
        guard let command = SDUICommand(rawValue: name) else { throw SDUIRefusal(reason: "unknown_action") }
        var allowed: Set<String> = ["command", "confirm"]
        if let argument = command.argument { allowed.insert(argument) }
        try sduiRequire(Set(m.keys).isSubset(of: allowed) && command.argument.map { m[$0] != nil } != false)
        var confirm: Bool? = nil
        if let value = m["confirm"] { confirm = try boolean(value) }
        try sduiRequire(command.isFormSubmit == submit, "action_context")
        try sduiRequire(!command.isFlowStep || inFlow, "action_context")
        let argument: SDUIAction.Argument?
        switch command.argument {
        case "text"?:
            argument = .text(try text(m["text"]))
        case "url"?:
            guard case .string(let url)? = m["url"] else { throw invalid }
            try sduiRequire(url.utf8.count <= SDUICatalog.maxURLBytes && matches(url, SDUICatalog.urlPattern),
                            "url_not_allowed")
            let host = String(url.dropFirst("https://".count).prefix { $0 != "/" && $0 != "?" })
            try sduiRequire(policy.urlHosts.contains(host), "url_not_allowed")
            argument = .url(url)
        case "screen"?:
            guard case .string(let screen)? = m["screen"] else { throw invalid }
            try sduiRequire(!SDUICatalog.deniedSurface(screen), "denied_route")
            guard let known = SDUIScreen(rawValue: screen) else { throw SDUIRefusal(reason: "unknown_action") }
            argument = .screen(known)
        case "routine"?:
            argument = .routine(try bindingObject(m["routine"]))
        default:
            argument = nil
        }
        return SDUIAction(command: command, argument: argument, confirm: confirm)
    }

    func field(_ value: JCS.Value, seen: inout Set<String>) throws -> SDUIField {
        let m = try object(value)
        let keys = Set(m.keys)
        try sduiRequire(keys.isSubset(of: SDUICatalog.fieldMembers) && keys.isSuperset(of: ["id", "kind", "label"]))
        let id = try name(m["id"])
        try sduiRequire(!SDUICatalog.deniedSegment(id), "denied_binding")
        try sduiRequire(seen.insert(id).inserted)
        guard case .string(let kindName)? = m["kind"] else { throw invalid }
        try sduiRequire(!SDUICatalog.deniedSurface(kindName), "denied_route")
        guard let kind = SDUIFieldKind(rawValue: kindName) else { throw SDUIRefusal(reason: "unknown_component") }
        let extra: [(String, Set<SDUIFieldKind>)] = [("placeholder", [.text, .multiline]), ("max_length", [.text, .multiline]),
                                                    ("options", [.choice]), ("types", [.filePick])]
        for (member, kinds) in extra { try sduiRequire(m[member] == nil || kinds.contains(kind)) }
        try sduiRequire(kind != .choice || m["options"] != nil)
        let label = try text(m["label"])
        var required: Bool? = nil
        if let value = m["required"] { required = try boolean(value) }
        var placeholder: String? = nil
        if let value = m["placeholder"] {
            guard case .string(let text) = value else { throw invalid }
            try literal(text)
            placeholder = text
        }
        var options: [SDUIOption]? = nil
        if let value = m["options"] {
            var values: Set<String> = []
            options = try items(value, nonempty: true).map { item in
                let option = try object(item)
                try sduiRequire(Set(option.keys) == ["value", "label"])
                guard case .string(let optionValue)? = option["value"], matches(optionValue, SDUICatalog.optionPattern),
                      values.insert(optionValue).inserted else { throw invalid }
                return SDUIOption(value: optionValue, label: try text(option["label"]))
            }
        }
        var maxLength: Int64? = nil
        if let value = m["max_length"] { maxLength = try integer(value, 1, Int64(policy.limits.maxStringBytes)) }
        var types: [String]? = nil
        if case .array(let list)? = m["types"] {
            try sduiRequire((1...SDUICatalog.maxFileTypes).contains(list.count))
            let names = try list.map { item -> String in
                guard case .string(let type) = item, matches(type, SDUICatalog.fileTypePattern) else { throw invalid }
                return type
            }
            try sduiRequire(Set(names.map { Array($0.utf8) }).count == names.count)
            types = names
        } else if m["types"] != nil {
            throw invalid
        }
        var bound: SDUIBinding? = nil
        if let value = m["value"] { bound = try bindingObject(value) }
        var visibleIf: SDUIPredicate? = nil
        if let value = m["visible_if"] { visibleIf = try predicate(value) }
        return SDUIField(id: id, kind: kind, label: label, required: required, placeholder: placeholder, options: options,
                         maxLength: maxLength, types: types, value: bound, visibleIf: visibleIf)
    }
}
