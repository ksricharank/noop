import SwiftUI
import MarkdownUI
import StrandDesign

/// The MarkdownUI theme for Coach replies.
///
/// LLM chat replies (OpenAI / Anthropic / Gemini) arrive as GitHub-flavored
/// Markdown — overwhelmingly bold, bullet/numbered lists, `###` headings, and the
/// occasional table for a weekly plan. This theme renders that set in the Strand
/// look, sized for a chat bubble: headings are capped near body size (a `#` must
/// not shout inside a 560pt bubble), and tables get hairline borders.
extension Theme {
    /// The summary-card variant of `.strand` (Today, Sleep, Recap, Insights): identical styling with the
    /// base text one step below chat, in the secondary tone. Everything else (bold, lists, the rare
    /// heading) inherits the chat theme below.
    ///
    /// 261007: one step up the iOS text scale, 13 (footnote) → 15 (subheadline), maintainer request
    /// ("make all the LLM outputs one font size higher") — the summaries had become the screens' main
    /// read, and footnote size suited a paragraph that was sitting in for the rule-based line.
    static let strandSynthesis = Theme.strand
        .text {
            ForegroundColor(StrandPalette.textSecondary)
            FontSize(15)
        }

    static let strand = Theme()
        // Base body text: 16 (callout), one step up from 15 on 261007 with the summary cards above.
        // Headings h3/h4 moved with it so no heading renders smaller than the body around it.
        .text {
            ForegroundColor(StrandPalette.textPrimary)
            FontSize(16)
        }
        // BOLD, not semibold (260904, maintainer: "the coach response format doesn't show bold
        // text correctly").
        //
        // `.semibold` against a 15pt regular body is a ~100-weight step, and on the frosted
        // Charge-tinted bubble that difference is nearly invisible — so a reply that was correctly
        // emphasised looked like one where the bold had been dropped. LLM replies lean on bold as
        // their primary structure (it is by far the most common markup they emit), so this is the
        // one weight in the theme that has to be unmistakable.
        //
        // Deliberately not applied to headings, which stay semibold: they are already separated by
        // size and margin, and a full bold heading inside a 560pt bubble is the shouting the theme
        // doc warns about.
        .strong {
            FontWeight(.bold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(StrandPalette.accentHover)
            BackgroundColor(StrandPalette.surfaceInset)
        }
        .link {
            ForegroundColor(StrandPalette.accent)
        }
        // Headings: h1/h2/h3 at headline (17 / semibold), h4 at body size,
        // h5–h6 as overline-ish small labels.
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(12)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .markdownTextStyle {
                    ForegroundColor(StrandPalette.textSecondary)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(StrandPalette.accent.opacity(0.6))
                        .frame(width: 3)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(10)
            }
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .markdownMargin(top: 4, bottom: 8)
        }
        .thematicBreak {
            StrandPalette.hairline
                .frame(height: 1)
                .markdownMargin(top: 10, bottom: 10)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: StrandPalette.hairline))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, StrandPalette.surfaceInset)
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    FontSize(.em(0.9))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .relativeLineSpacing(.em(0.2))
        }
}
