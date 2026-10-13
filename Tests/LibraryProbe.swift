import Foundation
import Darwin

/// Integration check against the signed-in wrapper account. Prints counts only;
/// credentials, response bodies and library metadata stay out of test logs.
@main struct LibraryProbe {
    static func main() async throws {
        setbuf(stdout, nil)
        // Uses the wrapper address saved by the app (Settings › Wrapper).
        let wrapper = WrapperService(endpoint: .saved)
        let account = try await wrapper.account()
        guard account.authenticated else { throw ClientError.message("Sign into the wrapper before running this integration test.") }
        let service = LibraryService(wrapper: wrapper)
        for category in LibraryCategory.allCases {
            var next: String? = "/v1/me/library/\(category.rawValue)"
            var seen = Set<String>(); var pages = 0; var total = 0; var playable = 0
            var firstCollection: LibraryItem?
            while let path = next {
                guard seen.insert(path).inserted else { throw ClientError.message("Pagination loop") }
                let url = try LibraryService.url(for: path)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if category == .songs { precondition(query.contains { $0.name == "include" && $0.value == "catalog" }) }
                let page = try await service.page(path, account: account)
                if firstCollection == nil { firstCollection = page.data.first(where: { $0.trackPath != nil }) }
                pages += 1; total += page.data.count; playable += page.data.filter(\.playable).count; next = page.next
                if pages % 20 == 0 { print(category.rawValue, "loaded pages:", pages, "items:", total) }
            }
            print(category.rawValue, "pages:", pages, "items:", total, "playable songs:", playable)
            if let firstCollection, let path = firstCollection.trackPath {
                let page = try await service.page(path, account: account)
                print(category.rawValue, "detail page tracks:", page.data.count, "catalog mappings:", page.data.filter(\.playable).count)
            }
        }
        for invalid in ["https://evil.test/v1/me/library/songs", "//evil.test/v1/me/library/songs", "https://api.music.apple.com.evil.test/v1/me/library/songs", "https://api.music.apple.com/v1/catalog/de/songs", "http://api.music.apple.com/v1/me/library/songs"] {
            do { _ = try LibraryService.url(for: invalid); throw ClientError.message("Unsafe pagination URL accepted") }
            catch let error as ClientError { if error.errorDescription == "Unsafe pagination URL accepted" { throw error } }
        }
        let uploaded = Data(#"{"id":"i.uploaded","type":"library-songs","attributes":{"name":"Uploaded song","playParams":{"id":"i.uploaded","isLibrary":true}}}"#.utf8)
        let item = try JSONDecoder().decode(LibraryItem.self, from: uploaded)
        precondition(!item.playable && item.catalogID == nil)
        print("Library integration, catalog mapping and pagination checks passed")
    }
}
