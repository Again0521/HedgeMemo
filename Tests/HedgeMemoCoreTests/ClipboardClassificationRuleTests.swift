import XCTest

@testable import HedgeMemoCore

@MainActor
final class ClipboardClassificationRuleTests: XCTestCase {
    private func tempRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgememo-rules-\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAllModeCombinesContentAndStableSourceApplication() {
        let category = CustomClipboardCategory(
            name: "Safari 工作",
            matchMode: .all,
            rules: [
                ClipboardClassificationRule(kind: .contains, value: "WORK-"),
                ClipboardClassificationRule(kind: .sourceApplication, value: "com.apple.Safari"),
            ]
        )
        let safari = ClipboardEntry(
            kind: .text,
            text: "WORK-123",
            contentHash: "work",
            sourceApp: "Safari",
            sourceBundleIdentifier: "com.apple.Safari"
        )
        var notes = safari
        notes.sourceApp = "Notes"
        notes.sourceBundleIdentifier = "com.apple.Notes"

        XCTAssertTrue(category.matches(safari))
        XCTAssertFalse(category.matches(notes))
    }

    func testAnyModeAndNegatedRules() {
        let category = CustomClipboardCategory(
            name: "外部链接",
            matchMode: .all,
            rules: [
                ClipboardClassificationRule(kind: .contains, value: "https://"),
                ClipboardClassificationRule(
                    kind: .contains,
                    value: "internal.example",
                    isNegated: true
                ),
            ]
        )
        XCTAssertTrue(category.matches("https://openai.com"))
        XCTAssertFalse(category.matches("https://internal.example/docs"))

        let either = CustomClipboardCategory(
            name: "任一",
            matchMode: .any,
            rules: [
                ClipboardClassificationRule(kind: .startsWith, value: "TODO"),
                ClipboardClassificationRule(kind: .endsWith, value: "#later"),
            ]
        )
        XCTAssertTrue(either.matches("TODO buy milk"))
        XCTAssertTrue(either.matches("read this #later"))
        XCTAssertFalse(either.matches("finished"))
    }

    func testCaseSensitivityAndRegularExpressionRules() {
        let insensitive = CustomClipboardCategory(
            name: "Insensitive",
            rules: [ClipboardClassificationRule(kind: .contains, value: "hedge")]
        )
        let sensitive = CustomClipboardCategory(
            name: "Sensitive",
            rules: [
                ClipboardClassificationRule(
                    kind: .regularExpression,
                    value: "^Hedge[A-Z]+$",
                    isCaseSensitive: true
                )
            ]
        )
        XCTAssertTrue(insensitive.matches("HedgeMemo"))
        XCTAssertTrue(sensitive.matches("HedgeMEMO"))
        XCTAssertFalse(sensitive.matches("hedgeMEMO"))
    }

    func testContentTypeRulesSupportTextAndImageEntries() {
        let codeCategory = CustomClipboardCategory(
            name: "代码",
            rules: [
                ClipboardClassificationRule(
                    kind: .contentType,
                    value: ClipboardContentCategory.code.rawValue
                )
            ]
        )
        let imageCategory = CustomClipboardCategory(
            name: "图片",
            rules: [
                ClipboardClassificationRule(
                    kind: .contentType,
                    value: ClipboardContentCategory.image.rawValue
                )
            ]
        )
        let code = Fixture.text("let answer = 42", hash: "code")
        let image = Fixture.image(hash: "image")

        XCTAssertTrue(codeCategory.matches(code))
        XCTAssertFalse(codeCategory.matches(image))
        XCTAssertTrue(imageCategory.matches(image))
        XCTAssertTrue(image.supportsManualCategory(.custom(imageCategory.id)))
    }

    func testAutomaticRulesNeverSurfaceSecretsOutsidePasswordCategory() {
        let broad = CustomClipboardCategory(
            name: "Everything",
            rules: [ClipboardClassificationRule(kind: .contains, value: "cipher")]
        )
        let secret = ClipboardEntry(
            kind: .text,
            text: "ciphertext",
            contentHash: "secret",
            origin: .concealedPassword
        )
        XCTAssertFalse(broad.matches(secret))
        XCTAssertFalse(secret.matches(key: .custom(broad.id), customCategories: [broad]))
        XCTAssertThrowsError(
            try ClipboardClassificationRule(
                kind: .contentType,
                value: ClipboardContentCategory.password.rawValue
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? ClipboardClassificationRuleError,
                .invalidContentType(ClipboardContentCategory.password.rawValue)
            )
        }
    }

    func testLegacyRegexCategoryDecodesAsSingleRule() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Ticket",
          "pattern": "^JIRA-[0-9]+"
        }
        """
        let category = try JSONDecoder().decode(
            CustomClipboardCategory.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(category.resolvedMatchMode, .all)
        XCTAssertEqual(category.effectiveRules.count, 1)
        XCTAssertEqual(category.effectiveRules.first?.kind, .regularExpression)
        XCTAssertTrue(category.effectiveRules.first?.isCaseSensitive == true)
        XCTAssertTrue(category.matches("JIRA-123 fix"))
        XCTAssertFalse(category.matches("jira-123 fix"))
    }

    func testRuleValidationThrowsSpecificErrors() {
        XCTAssertThrowsError(
            try CustomClipboardCategory(name: "Empty", matchMode: .all, rules: []).validate()
        ) {
            XCTAssertEqual($0 as? ClipboardClassificationRuleError, .noRules)
        }
        XCTAssertThrowsError(
            try ClipboardClassificationRule(kind: .regularExpression, value: "([").validate()
        ) {
            XCTAssertEqual(
                $0 as? ClipboardClassificationRuleError,
                .invalidRegularExpression("([")
            )
        }
        XCTAssertThrowsError(
            try ClipboardClassificationRule(kind: .contentType, value: "unknown").validate()
        ) {
            XCTAssertEqual(
                $0 as? ClipboardClassificationRuleError,
                .invalidContentType("unknown")
            )
        }
        let tooMany = (0..<9).map {
            ClipboardClassificationRule(id: UUID(), kind: .contains, value: "\($0)")
        }
        XCTAssertThrowsError(
            try CustomClipboardCategory(name: "Many", rules: tooMany).validate()
        ) {
            XCTAssertEqual($0 as? ClipboardClassificationRuleError, .tooManyRules(9))
        }
    }

    func testRulesPersistAndInvalidPersistedRuleSurfacesWithoutDroppingHistory() throws {
        let root = tempRoot("persistence")
        let repository = ClipboardHistoryRepository(rootURL: root)
        let valid = CustomClipboardCategory(
            name: "Safari",
            matchMode: .any,
            rules: [
                ClipboardClassificationRule(kind: .sourceApplication, value: "com.apple.Safari")
            ]
        )
        let entry = ClipboardEntry(kind: .text, text: "kept", contentHash: "kept")
        try repository.save(
            ClipboardHistorySnapshot(
                entries: [entry],
                settings: ClipboardHistorySettings(customCategories: [valid])
            )
        )
        var reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.map(\.id), [entry.id])
        XCTAssertEqual(
            reloaded.settings.customCategories?.first?.effectiveRules.first?.kind,
            .sourceApplication
        )

        let invalid = CustomClipboardCategory(
            name: "Broken",
            matchMode: .all,
            rules: [ClipboardClassificationRule(kind: .regularExpression, value: "(")]
        )
        try repository.save(
            ClipboardHistorySnapshot(
                entries: [entry],
                settings: ClipboardHistorySettings(customCategories: [invalid])
            )
        )
        reloaded = ClipboardHistoryStore(repository: repository)
        XCTAssertEqual(reloaded.entries.map(\.id), [entry.id])
        XCTAssertEqual(reloaded.lastError, ClipboardClassificationRuleError.invalidRegularExpression("(").localizedDescription)
    }
}
