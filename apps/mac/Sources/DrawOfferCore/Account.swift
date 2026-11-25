import Foundation

/// 桌面账号页白名单（与后端 `get_current_account_user` 对齐）：资料、昵称、联系邮箱、偏好与求职画像。
/// 头像上传与移除也在其中；桌面端不提供密码、微信绑定与注销账号。
public enum AccountRequest {
    public static func allowed(path: String, method: String) -> Bool {
        switch path {
        case "/api/account/profile", "/api/account/preferences": return ["GET", "PATCH"].contains(method)
        case "/api/account/contact-email": return method == "PUT"
        case "/api/account/user-profile": return ["GET", "PUT"].contains(method)
        case "/api/account/avatar": return ["PUT", "DELETE"].contains(method)
        case "/api/account/career-profile": return ["GET", "PUT"].contains(method)
        case "/api/account/career-profile/read-resume": return method == "POST"
        default: return false
        }
    }

    public static func errorMessage(_ error: Error, fallback: String) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。" }
        guard case APIError.server(_, let code) = error else { return fallback }
        return [
            "INVALID_NICKNAME": "昵称需要 1–50 个字符。",
            "INVALID_CONTACT_EMAIL": "请输入有效的邮箱地址。",
            "INVALID_ACCOUNT_PREFERENCES": "偏好设置无效，请刷新后重试。",
            "USER_PROFILE_VERSION_CONFLICT": "求职资料已在其他设备更新，已为你读取最新版本，请确认后再保存。",
            "INVALID_IMAGE": "只支持 PNG 或 JPEG 图片。",
            "IMAGE_TOO_LARGE": "图片超过 10 MB，请换一张。",
            "ASSET_UPLOAD_FAILED": "头像上传失败，请稍后重试。",
            "DESKTOP_ROUTE_FORBIDDEN": "桌面端不提供此操作。",
        ][code] ?? fallback
    }
}
