import XCTest
@testable import HermesMobile

/// Pure display-layer logic behind the transcript's reasoning blocks, echo
/// stripping, and per-row content scans.
final class ChatTranscriptReasoningDisplayTests: XCTestCase {
    // MARK: - ReasoningGroupAnchorLookup (P1)

    func testReasoningGroupAnchorLookupReturnsGroupsByAnchor() {
        let lookup = ReasoningGroupAnchorLookup(groups: [
            ReasoningGroup(id: "reasoning-a-1", anchorMessageID: "assistant-a", text: "First thought."),
            ReasoningGroup(id: "reasoning-loose", anchorMessageID: nil, text: "Loose thought."),
            ReasoningGroup(id: "reasoning-b", anchorMessageID: "assistant-b", text: "Second thought."),
            ReasoningGroup(id: "reasoning-a-2", anchorMessageID: "assistant-a", text: "More on the first turn.")
        ])

        XCTAssertEqual(
            lookup.groups(anchorMessageID: "assistant-a").map(\.id),
            ["reasoning-a-1", "reasoning-a-2"]
        )
        XCTAssertEqual(lookup.groups(anchorMessageID: "assistant-b").map(\.id), ["reasoning-b"])
        XCTAssertEqual(lookup.groups(anchorMessageID: nil).map(\.id), ["reasoning-loose"])
        XCTAssertTrue(lookup.groups(anchorMessageID: "missing").isEmpty)
    }

    func testReasoningDisplayGroupsSlicePerAnchorThroughTheViewModelMapping() {
        let messages = [
            user("u1"),
            assistant("a1", content: "First answer.", reasoning: "First thought."),
            user("u2"),
            assistant("a2", content: "Second answer.", reasoning: "Second thought.")
        ]

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])
        let lookup = ReasoningGroupAnchorLookup(groups: groups)

        XCTAssertEqual(
            lookup.groups(anchorMessageID: "a1").map(\.text),
            ["First thought."]
        )
        XCTAssertEqual(
            lookup.groups(anchorMessageID: "a2").map(\.text),
            ["Second thought."]
        )
        XCTAssertTrue(lookup.groups(anchorMessageID: "u1").isEmpty)
        XCTAssertTrue(lookup.groups(anchorMessageID: nil).isEmpty)
    }

    // MARK: - strippedVisibleAssistantEcho byte identity (P2b)

    func testReasoningWithoutVisibleEchoIsPreservedVerbatim() {
        let groups = reasoningGroups(
            content: "The answer is 42.",
            reasoning: "I should compute the meaning of life first."
        )

        XCTAssertEqual(groups.map(\.text), ["I should compute the meaning of life first."])
    }

    func testReasoningStripsAnExactVisibleParagraphEcho() {
        let groups = reasoningGroups(
            content: "Final answer text goes here etc.",
            reasoning: "Let me think about this problem carefully.\n\nFinal answer text goes here etc."
        )

        XCTAssertEqual(groups.map(\.text), ["Let me think about this problem carefully."])
    }

    func testReasoningKeepsAnEchoWithDifferentWhitespace() {
        let groups = reasoningGroups(
            content: "Different whitespace echo paragraph!",
            reasoning: "Preamble stays put.\n\nDifferent whitespace  echo paragraph!"
        )

        XCTAssertEqual(groups.map(\.text), ["Preamble stays put.\n\nDifferent whitespace  echo paragraph!"])
    }

    func testReasoningStripsEveryMatchingParagraphOfMultiParagraphContent() {
        let groups = reasoningGroups(
            content: "Alpha paragraph is long enough here.\n\nBeta paragraph is also long enough.",
            reasoning: """
            Alpha paragraph is long enough here.

            Beta paragraph is also long enough.

            Gamma survives the strip.
            """
        )

        XCTAssertEqual(groups.map(\.text), ["Gamma survives the strip."])
    }

    func testReasoningFullyCoveredByVisibleContentDropsTheGroup() {
        let groups = reasoningGroups(
            content: "The whole reasoning is just the visible answer repeated.",
            reasoning: "The whole reasoning is just the visible answer repeated."
        )

        XCTAssertTrue(groups.isEmpty)
    }

    func testReasoningWithEmptyVisibleTextIsPreserved() {
        for visible in [nil, "", "   "] {
            let groups = reasoningGroups(
                content: visible,
                reasoning: "No visible paragraphs to strip here at all."
            )

            XCTAssertEqual(
                groups.map(\.text),
                ["No visible paragraphs to strip here at all."],
                "visible text: \(visible.map { "'\($0)'" } ?? "nil")"
            )
        }
    }

    func testReasoningShorterThanTheEchoThresholdIsNeverStripped() {
        // Visible paragraphs under 20 characters are not echo candidates, so
        // identical short text must survive.
        let groups = reasoningGroups(content: "Short answer.", reasoning: "Short answer.")

        XCTAssertEqual(groups.map(\.text), ["Short answer."])
    }

    // MARK: - Row content truth tables (P5)

    func testTranscriptRowsRequireNonWhitespaceContentOrAttachments() {
        let hugeWhitespacePadded = String(repeating: " \n\t", count: 100_000) + "visible tail"

        XCTAssertEqual(rowIncluded(assistant(content: nil)), false)
        XCTAssertEqual(rowIncluded(assistant(content: "")), false)
        XCTAssertEqual(rowIncluded(assistant(content: "   \n\t  ")), false)
        XCTAssertEqual(rowIncluded(assistant(content: "visible")), true)
        XCTAssertEqual(rowIncluded(assistant(content: "🎉")), true)
        XCTAssertEqual(rowIncluded(assistant(content: hugeWhitespacePadded)), true)
    }

    func testUserTurnBoundariesRequireNonWhitespaceContentOrAttachments() {
        XCTAssertEqual(isUserBoundary(user(content: nil, attachments: nil)), false)
        XCTAssertEqual(isUserBoundary(user(content: "", attachments: nil)), false)
        XCTAssertEqual(isUserBoundary(user(content: " \n\t ", attachments: nil)), false)
        XCTAssertEqual(isUserBoundary(user(content: "Do the thing", attachments: nil)), true)
        XCTAssertEqual(isUserBoundary(user(content: "🎉", attachments: nil)), true)
        XCTAssertEqual(isUserBoundary(user(content: nil, attachments: [MessageAttachment()])), true)
        XCTAssertEqual(isUserBoundary(user(content: " \n ", attachments: [MessageAttachment()])), true)

        // Assistant messages are never turn boundaries.
        XCTAssertEqual(isUserBoundary(assistant(content: "visible")), false)
    }

    func testToolResultOnlyClassificationMatchesVisibleContent() {
        XCTAssertEqual(isToolResultOnly(user(content: nil, attachments: nil)), true)
        XCTAssertEqual(isToolResultOnly(user(content: " \n\t ", attachments: nil)), true)
        XCTAssertEqual(isToolResultOnly(user(content: "🎉", attachments: nil)), false)
        XCTAssertEqual(isToolResultOnly(user(content: nil, attachments: [MessageAttachment()])), false)
        XCTAssertEqual(isToolResultOnly(assistant(content: nil)), false)
    }

    // MARK: - Helpers

    private func reasoningGroups(content: String?, reasoning: String) -> [ReasoningGroup] {
        ChatViewModel.reasoningDisplayGroups(
            messages: [assistant("a1", content: content, reasoning: reasoning)],
            archivedGroups: []
        )
    }

    /// Whether `transcriptMessages` keeps the message, i.e. its row-content
    /// check passed (activity anchors are left empty so only content decides).
    private func rowIncluded(_ message: ChatMessage) -> Bool {
        !ChatViewModel.transcriptMessages(
            from: [message],
            renderedActivityAnchorIDs: []
        ).isEmpty
    }

    private func isUserBoundary(_ message: ChatMessage) -> Bool {
        TranscriptTurnClassifier.isUserTurnBoundary(message)
    }

    private func isToolResultOnly(_ message: ChatMessage) -> Bool {
        TranscriptTurnClassifier.isToolResultOnlyMessage(message)
    }

    private func user(
        _ id: String = "u1",
        content: String?,
        attachments: [MessageAttachment]? = nil
    ) -> ChatMessage {
        ChatMessage(role: "user", content: content, timestamp: 100, messageId: id, attachments: attachments)
    }

    private func assistant(
        _ id: String = "a1",
        content: String?,
        reasoning: String? = nil
    ) -> ChatMessage {
        ChatMessage(role: "assistant", content: content, timestamp: 110, messageId: id, reasoning: reasoning)
    }
}
