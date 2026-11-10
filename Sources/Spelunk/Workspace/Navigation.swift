import Foundation

/// Why the editor moved. Navigation state that used to be reset ad hoc by each entry point (the
/// current code-path step, which subject the context pane shows, which pane is open) is decided
/// here from the reason, in one place.
enum NavReason: Equatable {
    case hunk, step, thread, symbol, definition, reference, history, citation, search, manual
    /// Opening a file from the Files tab, search results or the palette.
    case browse
    /// A click inside the code: updates the symbol context but is not a move.
    case click
}

extension Workspace {
    /// Starts a navigation and returns its generation. Async work started for it (loading a review
    /// document, resolving a definition) commits only while the generation is still current, so a
    /// slow answer never moves the editor after the user has gone somewhere else.
    @discardableResult
    func beginNavigation(_ reason: NavReason) -> Int {
        navGeneration += 1
        navReason = reason
        if reason != .step && reason != .click { traces.currentStepID = nil }
        switch reason {
        case .hunk:
            diffShown = true
            if !contextPinned { contextFocus = .hunk }
            if inspectorPane == .paths { inspectorPane = .context }
        case .step:
            inspectorPane = .paths
        case .symbol, .click, .definition:
            if !contextPinned { contextFocus = .symbol }
        case .thread:
            diffShown = true
        case .browse:
            if review?.follows == true { diffShown = false }
        default:
            break
        }
        return navGeneration
    }

    func isCurrentNavigation(_ generation: Int) -> Bool { generation == navGeneration }

    /// The context pane shows the selected hunk's change context (rather than a symbol).
    var showsHunkContext: Bool {
        reviewing && changeContext != nil && contextFocus == .hunk && !contextPinned
    }

    /// Closes the review being shown and returns to the working copy: its head rust-analyzer stops,
    /// and a file open at the review's version reopens as the working copy at the same line.
    func closeActiveReview() {
        guard let key = activeReviewKey else { return }
        let doc = document, line = cursor?.line ?? 0
        closeReview(key)
        if let doc, !doc.isWorkingCopy, doc.side != .old {
            open(CodeLocation(path: doc.path, range: SourceRange(line: line)), record: false, reason: .manual)
        }
        statusMessage = "Back to the working copy"
    }

    /// Makes a review active (nil: the working-copy review). Selection that belongs to the previous
    /// review is cleared, then the new review's first hunk is selected.
    /// `showList` brings the Review tab forward, for requests to open a review rather than to close one.
    func activateReview(_ key: String?, showList: Bool = true) {
        if key != activeReviewKey {
            diffShown = true
            activeReviewKey = key
            selectedHunkID = nil
            changeContext = nil
            commentDraft = nil
            currentThreadID = nil
            splitDocument = nil
            traces.currentStepID = nil
        }
        if showList { sidebarTab = .changes }
        if let r = review, !r.follows {
            Task {
                await checkFreshness([r])
                if case .githubPR = r.target { await r.refreshPullRequest() }
            }
        }
        if let r = review, r.state == .ready, selectedHunkID == nil, let h = r.tierSections.first?.hunks.first ?? r.allHunks.first {
            selectHunk(h)
        }
    }
}
