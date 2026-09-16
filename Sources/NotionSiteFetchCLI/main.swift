import Foundation
import NotionSiteFetch

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

@main
struct NotionSiteFetchCommand {
    static let helpText = """
    notion-site-fetch — print a public Notion page as Markdown to stdout.

    USAGE
        notion-site-fetch <url>

    Converts any publicly-readable Notion page into Markdown. No API token,
    no login, no headless browser — just plain HTTPS calls to Notion's
    public endpoints. If the page loads in an anonymous browser tab, this
    tool can fetch it.

    ACCEPTED URLS
        https://<sub>.notion.site/                      site root (public home page)
        https://<sub>.notion.site/<slug-or-pageid>      any page on a public site
        https://www.notion.so/<...>-<32-char-page-id>   notion.so page URL

    OUTPUT
        Markdown is written to stdout. Use shell redirection to save:
            notion-site-fetch <url> > page.md
            notion-site-fetch <url> >> notes.md
        Errors go to stderr; exit code is non-zero on failure.

    NOTES
        - Only the requested page is fetched. Sub-pages linked from it
          remain as links — run the tool again with each sub-page URL.
        - Toggle/dropdown contents are expanded inline (no hidden text).
        - Private or login-required pages fail with a clear error message.

    """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["-h"] || arguments == ["--help"] {
            FileHandle.standardOutput.write(Data(helpText.utf8))
            return
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data(helpText.utf8))
            exit(1)
        }

        do {
            let page = try await NotionSiteFetcher().fetchPage(from: arguments[0]) { stage in
                FileHandle.standardError.write(Data("\(stage.rawValue)\n".utf8))
            }
            FileHandle.standardOutput.write(Data(page.markdown.utf8))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
