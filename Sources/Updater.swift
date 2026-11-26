// Новая версия: раз в неделю Lark спрашивает у GitHub файл VERSION (ничего о вас не отправляется). Есть новее —
// в шестерёнке появляется «Обновить до …»: Lark запускает ту же команду установки в фоне и перезапускается сам.
import Foundation

enum Updater {
    static let repo = "Egrom92/lark"
    static let versionURL = URL(string: "https://raw.githubusercontent.com/\(repo)/main/VERSION")!
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | bash"
    static let week: TimeInterval = 7 * 24 * 3600

    static var local: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Известная новая версия (с прошлой проверки), если она новее установленной.
    static var available: String? {
        guard let v = UserDefaults.standard.string(forKey: "latestVersion"), isNewer(v, than: local) else { return nil }
        return v
    }

    /// Проверить, если с прошлого раза прошла неделя (или force). done — на главном потоке: новая версия или nil
    /// и удалось ли спросить GitHub (нет сети — false, тогда «у вас последняя версия» говорить нельзя).
    static func check(force: Bool = false, done: @escaping (String?, Bool) -> Void) {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > week else { done(available, true); return }
        var req = URLRequest(url: versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Lark/\(local)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let v = ok ? data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
            DispatchQueue.main.async {
                var reached = false
                if let v, !v.isEmpty {
                    UserDefaults.standard.set(v, forKey: "latestVersion")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                    reached = true
                }
                done(available, reached)
            }
        }.resume()
    }

    /// Обновить: команда установки в фоне (журнал — ~/Library/Logs/Lark-update.log). Установщик закроет и снова откроет Lark.
    /// failed — на главном потоке, если установщик завершился, а Lark всё ещё работает: при успехе установщик
    /// закрывает Lark раньше, чем заканчивает сам, так что сюда доходит только неудача (нет сети, сборка не прошла).
    static func install(failed: @escaping () -> Void) {
        let log = NSHomeDirectory() + "/Library/Logs/Lark-update.log"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", "-c", "\(installCommand) >> '\(log)' 2>&1"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in DispatchQueue.main.async { failed() } }
        do { try p.run() } catch { failed() }
    }
}
