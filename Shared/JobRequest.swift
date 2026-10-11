import Foundation

/// Finder 扩展 → 主程序 的任务请求。
/// 编码为 sevenzipmac://job?d=<base64url(JSON)>，由扩展用 NSWorkspace 打开。
struct JobRequest: Codable, Equatable {

    enum Op: String, Codable {
        case compress
        case extract
    }

    static let scheme = "sevenzipmac"
    static let host = "job"

    var op: Op
    var paths: [String]

    init(op: Op, paths: [String]) {
        self.op = op
        self.paths = paths
    }

    var url: URL? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = Self.host
        comps.queryItems = [URLQueryItem(name: "d", value: json.base64URLEncodedString())]
        return comps.url
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Data(base64URLEncoded: value),
              let req = try? JSONDecoder().decode(JobRequest.self, from: data)
        else { return nil }
        self = req
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let rem = b.count % 4
        if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: b)
    }
}
