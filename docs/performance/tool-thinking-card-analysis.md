# Hermex chat UI performance — findings on tool-call / thinking-card slowness

> **Status:** investigation doc for the tool-call / thinking-card path, mirroring the role of
> `long-streaming-message-analysis.md` for long streaming text. **P1, P2a, P2b, P4, P5, and P6 are now
> implemented** on branch `perf/chat-tool-thinking-cards` (commits 59448fb, fbc95cf, bae685e, dcc31d7).
> P3 (tool-card JSON caching) and the deferred structural slices (LazyVStack rows, incremental streaming
> Markdown state) remain open follow-ups. Validation still requires the macOS/Xcode pass described below.

Investigated 2026-09-04 at commit `8da603d` (fork of uzairansaruzi/hermex). Method: source-level analysis
(OpenCode plan mode, 203 steps, ~13 min) cross-verified by hand. No code changed. No Xcode available here,
so every fix needs the repo's standard validation (focused XCTest + simulator/Instruments) before merge.
Complements `docs/performance/long-streaming-message-analysis.md` (which covers long *assistant text*
streaming); this report covers the tool-call / thinking-card path the prior doc deferred (its §6).

## Publish cadence (the multiplier)

- Assistant text flushes: 48ms word-cadence tick (`ChatViewModel.swift:683-704`), 16ms coalescing (`:499`)
- Scroll-trigger bumps: 16ms (`:641-655`)
- Tool start/complete events: immediate (`:4451, :4492`)
- Reasoning: flushes whole per coalescing window (~16ms) (`:4410-4424`)

Every publish re-runs the full `ChatView.body` → `messageContent` (ChatView.swift:595-604, 1198).
`completedToolCallGroups` is equality-guarded and stable during streaming (`ChatViewModel.swift:4315-4322`) — good.
So the cost question is: what does one body pass cost?

## Ranked findings

### P1 — HIGH: per-row `.equatable()` compares the entire `[ReasoningGroup]` array
- `ChatTranscriptView.swift:284` passes the full `reasoningGroups` array to *every* row; `:571` compares it
  element-wise. The array is rebuilt every pass by `displayedReasoningGroups`, whose strings are fresh
  buffers (`trimmingCharacters`/`replacingOccurrences` allocate new storage each pass), so `String ==`
  cannot use the shared-storage fast path and byte-compares full texts.
- Cost: O(rows × total-reasoning-bytes) per pass. 50 rows × 100 KB of thinking = 5 MB of compares per pass,
  at 20-60 passes/s ⇒ hundreds of MB/s of main-thread scanning — even when a row renders nothing.
  This matches the "slow specifically with thinking cards" symptom.
- `toolCallGroups` (`:285`) is already per-anchor via `ToolCallGroupAnchorLookup` — the pattern to copy.
- Fix (low-risk): pre-index reasoning groups by anchor in the VM (mirror `ToolCallGroupAnchorLookup`,
  `ToolCall.swift:713-725`), pass each row only its own slice; non-anchor rows compare `[]` in O(1).
  = prior doc §6 exactly.

### P2 — HIGH: `displayedReasoningGroups` recomputed every pass, with an O(paragraphs × reasoning) echo-stripper
- Computed on every read (`ChatViewModel.swift:256-262`) — from `ChatView.swift:1200` per body pass **and**
  again from `recomputeDisplayedTranscriptMessages` on every `messages` mutation
  (`ChatViewModel.swift:203-205 → :285`), i.e. 2+ full runs per flush tick.
- Inside: `strippedVisibleAssistantEcho` (`:5875-5890`) splits the *entire visible content* into paragraphs,
  then calls `replacingOccurrences(of: paragraph)` on the full reasoning text once per paragraph ≥20 chars,
  reallocating even on no-match — O(P×R) with allocation churn.
- `normalizedReasoningKey` (`:5892-5897`) re-normalizes every full text twice per candidate (`:5663-5669`).
- Fix: (a) memoize the result alongside `recomputeDisplayedTranscriptMessages` (inputs are only
  `messages`/`messagesOffset`/`completedReasoningGroups`, all of which already have `didSet` hooks) so the
  body read is O(1); (b) guard each `replacingOccurrences` with a `contains` pre-check or bail when
  `visibleText` is nil/short.

### P3 — MEDIUM-HIGH: tool cards JSON-parse the full tool output twice, on every group re-eval
- `ToolActivityGroupView.swift:25` rebuilds all entries in `body`; `ToolCallSummaryFormatter.swift:63-81`
  calls `ToolCallDisplayFormatter.resultDisplay` (`ToolCallDisplayFormatter.swift:56-68`) **and**
  `envelopeReportsFailure` (`:32-46`) — each runs `parsedJSONValue` = `JSONDecoder` over the entire
  preview (`:282-284`). Per tool event, every call in the live group re-parses its whole output.
  `looksLikeFailure` (`ToolCallSummaryFormatter.swift:362-366`) also `split`s the entire preview to read one line.
- Fix (medium risk, contained): cache formatted `ToolCallLogRow`s per call (keyed on id + completion +
  preview length) or compute at group construction; early-exit `looksLikeFailure` at the first newline.

### P4 — MEDIUM: turn-key classification runs 3-4× per pass
- `assistantTurnKeysByAnchorID` is run independently by `reasoningDisplayGroups` (`ChatViewModel.swift:5619`),
  `TranscriptTurnFolds.derive` (`TranscriptTurnFolding.swift:98`), and `terminalReplyRenderIDs`
  (`ChatMessageMeta.swift:18`, recomputed per pass from `ChatView.swift:1269` via `:1472-1481`).
- Fix (low-risk, mechanical): compute turn keys once per mutation in the VM and pass them to all consumers.

### P5 — MEDIUM: per-flush transcript recompute trims every message's full content
- `messages` didSet (`ChatViewModel.swift:203-205`) → `transcriptMessages` (`:5694-5747`) calls
  `hasTranscriptMessageRowContent` (`:5757-5763`) and `isToolResultOnlyMessage`→`hasVisibleUserContent`
  (`ChatMessage.swift:325-333`) — both `trimmingCharacters` the full content (scan + allocate) per message,
  including huge tool-result user messages. O(total transcript bytes) per flush tick.
- Fix (low-risk micro-win): early-exit "first non-whitespace character" scans instead of full trim+alloc.

### P6 — LOW-MED: live reasoning row linear costs per flush
- `ReasoningBlockView.swift:29-30` trims the full text per eval; `LiveReasoningTextView.updateUIView`
  re-assigns the full `sourceText` as `accessibilityLabel` each flush (`:238`); `onChange(of: text)`
  full-compares (`:198`). Linear but anchor-row-only — acceptable; the accessibility assignment is a
  free fix (set only when changed; the coordinator already tracks `renderedText`).

### P7 — LOW: transcript-level scans
- `hasDisplayedTranscriptMessage` O(rows) twice per pass (`ChatTranscriptView.swift:426, 434, 491-495`);
  loose-block filters at `:500, :509`. Cheap relative to the above; leave.

### Deferred (already owned by existing slices — do not duplicate)
- **VStack eager row realization** (`ChatTranscriptView.swift:251`) — tracked by upstream #32/#33
  (prior doc §A/§7). Scroll-open jank from first-time realization of 50 markdown rows belongs there.
- **Streaming markdown re-parse + O(N) content concat per flush** (`ChatViewModel.swift:4661-4696`) —
  covered by prior doc §B/§C and its incremental render-state proposal.

## Suggested order
1. P1 (per-anchor reasoning slices) + P2a (memoize) — biggest wins, low risk, both mirror existing patterns.
2. P2b, P5, P6 — small safe micro-wins.
3. P4 — mechanical consolidation.
4. P3 — contained but stateful; do after measuring 1-2.
5. LazyVStack and incremental markdown state remain their existing upstream slices.

Each fix should land with a focused XCTest (existing `ChatViewModelStreamingPaceTests` pattern) and a
simulator Instruments pass before merge. Acceptance mirrors the prior doc: byte-identical streamed content,
replay de-dup untouched, scroll-anchor contract intact.
