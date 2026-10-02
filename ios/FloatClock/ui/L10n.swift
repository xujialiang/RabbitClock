import Foundation

/// 本地化取值：L("key")；带参格式化：LF("key", args...)
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

/// 时间源的本地化显示名（key = "src.<id>"）
func srcName(_ src: TimeSource) -> String { L("src.\(src.id)") }

/// 时间源副标题：设备/NTP 源走本地化；JSON 源 = 主机名 + 本地化后缀；Date 源 = 主机名
func srcSubline(_ src: TimeSource) -> String {
    switch src.kind {
    case .device: return L("sub.device")
    case .sntp: return L("sub.beijing")
    case .json:
        let host = URL(string: src.url)?.host ?? src.sub
        return host + " · " + L("sub.api")
    default:
        return URL(string: src.url)?.host ?? src.sub
    }
}
