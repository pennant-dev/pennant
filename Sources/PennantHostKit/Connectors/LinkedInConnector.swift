import PennantCore
import Foundation
import MCP

/// LinkedIn as the signed-in member, through the self-serve "Share on LinkedIn" and "Sign In with LinkedIn using
/// OpenID Connect" products: post to the member's own feed (text, a link, or an image), comment, and delete their
/// own posts. LinkedIn does not let self-serve apps read the feed, comments, other people's posts, or messages;
/// those need its partner programs. Self-serve tokens last 60 days and cannot be refreshed: sign in again then.
struct LinkedInConnector: NativeConnector {
    static let id = "linkedin"
    let displayName = "LinkedIn"
    /// LinkedIn versions its REST API monthly by header; each version is supported for at least a year.
    static let apiVersion = "202609"

    var tools: [MCP.Tool] {
        [
            .make("whoami", "The signed-in LinkedIn member: name, email and member id.", readOnly: true),
            .make("create_post", "Publish a post on the member's own LinkedIn feed. Optionally attach a link (shown as an article card) or a local image.", properties: [
                "text": Prop.str("The post text. Hashtags and line breaks are kept."),
                "visibility": Prop.oneOf("Who can see it (default PUBLIC)", ["PUBLIC", "CONNECTIONS"]),
                "link_url": Prop.str("A web page to attach as an article card (optional)"),
                "link_title": Prop.str("Title for the article card (optional)"),
                "image_path": Prop.str("Absolute path of a PNG, JPG or GIF on the host Mac to attach (optional)"),
                "image_alt": Prop.str("Alt text for the image (optional)"),
            ], required: ["text"], readOnly: false, destructive: true),
            .make("comment", "Comment on a post as the member (their own posts, or any post they can see).", properties: [
                "post_urn": Prop.str("The post's URN, e.g. urn:li:share:123 or urn:li:ugcPost:123"),
                "text": Prop.str("Comment text"),
            ], required: ["post_urn", "text"], readOnly: false, destructive: true),
            .make("delete_post", "Delete one of the member's own posts.", properties: [
                "post_urn": Prop.str("The post's URN from create_post"),
            ], required: ["post_urn"], readOnly: false, destructive: true),
        ]
    }

    func call(_ tool: String, arguments a: [String: Value], api: ConnectorAPI) async throws -> String {
        switch tool {
        case "whoami":
            let me = try await userInfo(api)
            return "\(me["name"] as? String ?? "") <\(me["email"] as? String ?? "no email shared")> · member urn:li:person:\(me["sub"] as? String ?? "?")"

        case "create_post":
            let author = try await memberURN(api)
            var post: [String: Any] = [
                "author": author,
                "commentary": Self.escapeCommentary(try a.require("text")),
                "visibility": a.string("visibility") ?? "PUBLIC",
                "distribution": ["feedDistribution": "MAIN_FEED", "targetEntities": [], "thirdPartyDistributionChannels": []],
                "lifecycleState": "PUBLISHED",
                "isReshareDisabledByAuthor": false,
            ]
            if let path = a.string("image_path") {
                let image = try await uploadImage(path: path, owner: author, api: api)
                var media: [String: Any] = ["id": image]
                if let alt = a.string("image_alt") { media["altText"] = alt }
                post["content"] = ["media": media]
            } else if let link = a.string("link_url") {
                var article: [String: Any] = ["source": link]
                if let t = a.string("link_title") { article["title"] = t }
                post["content"] = ["article": article]
            }
            let (_, response) = try await api.send("POST", Self.rest("posts"), json: post, headers: Self.headers)
            let urn = response.value(forHTTPHeaderField: "x-restli-id") ?? response.value(forHTTPHeaderField: "x-linkedin-id") ?? "?"
            return "Posted to LinkedIn. Post URN: \(urn)\(urn.hasPrefix("urn:") ? "\nhttps://www.linkedin.com/feed/update/\(urn)/" : "")"

        case "comment":
            let urn = try a.require("post_urn")
            let actor = try await memberURN(api)
            let body: [String: Any] = ["actor": actor, "object": urn, "message": ["text": try a.require("text")]]
            let (_, response) = try await api.send("POST", Self.rest("socialActions/\(Self.encodeURN(urn))/comments"), json: body, headers: Self.headers)
            return "Commented. Comment id: \(response.value(forHTTPHeaderField: "x-restli-id") ?? "?")"

        case "delete_post":
            let urn = try a.require("post_urn")
            _ = try await api.send("DELETE", Self.rest("posts/\(Self.encodeURN(urn))"), headers: Self.headers.merging(["X-RestLi-Method": "DELETE"]) { a, _ in a })
            return "Deleted \(urn)."

        default:
            throw ConnectorAPI.Failure(status: 0, message: "Unknown tool \(tool).")
        }
    }

    // MARK: Helpers

    static let headers = ["LinkedIn-Version": apiVersion, "X-Restli-Protocol-Version": "2.0.0"]

    static func rest(_ path: String) -> URL { URL(string: "https://api.linkedin.com/rest/\(path)")! }

    static func encodeURN(_ urn: String) -> String {
        urn.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? urn
    }

    /// The Posts API reads its "little text" format: these characters must be escaped or the post is rejected
    /// or cut short. Hashtags are kept as typed.
    static func escapeCommentary(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\|{}@[]()<>*_~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private func userInfo(_ api: ConnectorAPI) async throws -> [String: Any] {
        try await api.json("GET", URL(string: "https://api.linkedin.com/v2/userinfo")!)
    }

    private func memberURN(_ api: ConnectorAPI) async throws -> String {
        guard let sub = try await userInfo(api)["sub"] as? String, !sub.isEmpty else {
            throw ConnectorAPI.Failure(status: 0, message: "LinkedIn did not return the member id; the app needs the OpenID Connect product (scopes openid and profile).")
        }
        return "urn:li:person:\(sub)"
    }

    /// Images API: initialize an upload for the member, PUT the bytes, return the image URN.
    private func uploadImage(path: String, owner: String, api: ConnectorAPI) async throws -> String {
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            throw ConnectorAPI.Failure(status: 0, message: "Could not read the image at \(path).")
        }
        guard data.count < 36_000_000 else { throw ConnectorAPI.Failure(status: 0, message: "The image is larger than LinkedIn accepts.") }
        let reply = try await api.json("POST", URL(string: "https://api.linkedin.com/rest/images?action=initializeUpload")!, json: ["initializeUploadRequest": ["owner": owner]], headers: Self.headers)
        guard let value = reply["value"] as? [String: Any], let upload = (value["uploadUrl"] as? String).flatMap(URL.init(string:)), let image = value["image"] as? String else {
            throw ConnectorAPI.Failure(status: 0, message: "LinkedIn did not return an upload address for the image.")
        }
        let type = ["png": "image/png", "gif": "image/gif"][fileURL.pathExtension.lowercased()] ?? "image/jpeg"
        _ = try await api.send("PUT", upload, body: data, contentType: type)
        return image
    }
}
