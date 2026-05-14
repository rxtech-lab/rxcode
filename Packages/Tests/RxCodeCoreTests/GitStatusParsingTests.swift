import Testing
@testable import RxCodeCore

// parseGitStatusPorcelain reads character at index 1 (the Y/worktree column).
// Staged-only changes (X=' ', Y=' ') fall through to the default case → counted as modified.
// This mirrors the existing app behaviour exactly.

@Suite("parseGitStatusPorcelain")
struct GitStatusParsingTests {

    @Test("Empty output — no changes")
    func emptyOutput() {
        let result = parseGitStatusPorcelain("")
        #expect(result.modified == 0)
        #expect(result.added == 0)
        #expect(result.deleted == 0)
    }

    @Test("Worktree-modified file ( M) counted as modified")
    func modifiedWorktree() {
        let result = parseGitStatusPorcelain(" M file.swift\n")
        #expect(result.modified == 1)
        #expect(result.added == 0)
        #expect(result.deleted == 0)
    }

    @Test("Index-modified file (M ) — Y=' ' falls through to default, counted as modified")
    func modifiedIndex() {
        let result = parseGitStatusPorcelain("M  file.swift\n")
        #expect(result.modified == 1)
    }

    @Test("Untracked file (??) counted as added")
    func untracked() {
        let result = parseGitStatusPorcelain("?? untracked.swift\n")
        #expect(result.added == 1)
    }

    @Test("Worktree-deleted file ( D) counted as deleted")
    func deletedWorktree() {
        let result = parseGitStatusPorcelain(" D removed.swift\n")
        #expect(result.deleted == 1)
    }

    @Test("Staged-only add (A ) — Y=' ' falls to default, counted as modified")
    func addedStaged() {
        let result = parseGitStatusPorcelain("A  newfile.swift\n")
        #expect(result.modified == 1)
        #expect(result.added == 0)
    }

    @Test("Staged-only delete (D ) — Y=' ' falls to default, counted as modified")
    func deletedStaged() {
        let result = parseGitStatusPorcelain("D  removed.swift\n")
        #expect(result.modified == 1)
        #expect(result.deleted == 0)
    }

    @Test("Both-modified conflict (MM) — Y='M', counted as modified")
    func bothModified() {
        let result = parseGitStatusPorcelain("MM conflict.swift\n")
        #expect(result.modified == 1)
    }

    @Test("Lines shorter than 2 chars are skipped")
    func shortLine() {
        let result = parseGitStatusPorcelain("M\n")
        #expect(result.modified == 0)
        #expect(result.added == 0)
        #expect(result.deleted == 0)
    }

    @Test("Mixed real-world output counted correctly")
    func mixedOutput() {
        // ' M' → modified (Y='M')
        // 'M ' → modified (Y=' ', default)
        // '??' → added    (Y='?')
        // ' D' → deleted  (Y='D')
        let output = """
         M modified_worktree.swift
        M  modified_index.swift
        ?? untracked.txt
         D deleted_worktree.swift
        """
        let result = parseGitStatusPorcelain(output)
        #expect(result.modified == 2)
        #expect(result.added == 1)
        #expect(result.deleted == 1)
    }
}
