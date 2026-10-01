# Editor drawing at the window toolbar boundary

## Symptoms and cause

On macOS 27, a new document in split mode showed a vertical line above the
line-number gutter, beside the close button, and a visible change in the toolbar
background at the editor/preview boundary. The line followed the source editor's
gutter rather than the sidebar divider.

AppKit's `NSView.clipsToBounds` defaults to false when linked against macOS 14 or
later (documented in `NSView.h`). The source editor's native scroll view therefore
allowed drawing outside its pane. Explicit clipping removed the gutter artifact.
The shared toolbar also needs an explicit background to avoid separate pane
backgrounds producing a visible transition, including after sidebar changes.

## Fix

- Set `clipsToBounds = true` on the source editor's scroll view.
- Apply the same setting to the native plain-text preview scroll view, the other
  custom `NSScrollView` creation path. Structured previews use SwiftUI scrolling.
- Give the workspace toolbar a visible `windowBackgroundColor` background through
  SwiftUI's public toolbar modifiers. The semantic system color follows appearance
  changes; standard toolbar controls and the sidebar remain system managed.

Do not remove the actual editor/preview divider or line-number ruler: those remain
useful inside the content area. Do not disable automatic scroll insets, which also
participate in find-bar and safe-area layout.

## Verification

`EditorScrollClippingTests` hosts the actual source editor and plain-text preview
in an AppKit window, checks clipping at two window sizes, and verifies that the
source ruler and preview text selection remain enabled.

Visual checks should cover a new split document, switching to editor-only and back,
opening and closing the sidebar, and resizing. Inspect both the line above the
gutter and the toolbar background above the editor/preview divider. A sidebar can
retain its native material; the two document panes share the toolbar background.

Run `swift test` for the complete unit suite and build the `MKTownEditor` Xcode
scheme to verify the app configuration.

On 2026-09-29 the app build succeeded and the complete suite ran 689 tests:
688 passed, including both new clipping tests. `LocalizationCatalogTests` failed
because an English localization was missing (`競合版あり` in that run). The same
empty entry exists in HEAD; the catalog was not changed for this drawing fix.
Visual checks of the final app confirmed a continuous toolbar background with
the sidebar both hidden and visible. The source-only transition was also checked
during the clipping investigation.

Reference: [Apple toolbar guidelines](https://developer.apple.com/design/human-interface-guidelines/toolbars).
