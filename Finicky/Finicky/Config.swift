import Foundation
import JavaScriptCore

var FNConfigPath: String = "~/.finicky.js"

public enum AppDescriptorType: String {
    case bundleId
    case appName
}

public struct AppDescriptorOptions {
    public var openInBackground: Bool

    public init(openInBackground: Bool) {
        self.openInBackground = openInBackground
    }
}

public struct AppDescriptor {
    public var value: String
    public var type: AppDescriptorType
    public var url: URL
    public var options: AppDescriptorOptions?

    public init(value: String, type: AppDescriptorType, url: URL, options: AppDescriptorOptions?) {
        self.value = value
        self.type = type
        self.url = url
        self.options = options
    }
}

open class FinickyConfig {
    var ctx: JSContext!
    var validateConfigJS : String?;
    var processUrlJS : String?;
    var validateLibJS : String?;
    var hasError: Bool = false;

    var dispatchSource: DispatchSourceFileSystemObject?
    var fileDescriptor: Int32 = -1
    var fileManager = FileManager.init();
    var lastModificationDate: Date? = nil;
    var toggleIconCallback:(_ hide: Bool) -> Void;
    var logToConsole:(_ message: String) -> Void;

    public init(toggleIconCallback: @escaping (_ hide: Bool) -> Void, logToConsoleCallback: @escaping (_ message: String) -> Void ) {
        self.toggleIconCallback = toggleIconCallback
        self.logToConsole = logToConsoleCallback
        listenToChanges();

        if let path = Bundle.main.path(forResource: "validate.js", ofType: nil ) {
            do {
                validateLibJS = try String(contentsOfFile: path, encoding: String.Encoding.utf8)
            }
            catch {
                validateLibJS = nil
            }
        }

        if let path = Bundle.main.path(forResource: "validateConfig.js", ofType: nil ) {
            do {
                validateConfigJS = try String(contentsOfFile: path, encoding: String.Encoding.utf8)
            }
            catch {
                validateConfigJS = nil
            }
        }

        if let path = Bundle.main.path(forResource: "processUrl.js", ofType: nil ) {
            do {
                processUrlJS = try String(contentsOfFile: path, encoding: String.Encoding.utf8)}
            catch {
                processUrlJS = nil
            }
        }
    }

    func getModificationDate(atPath: String) -> Date? {
        do {
            let attributes = try self.fileManager.attributesOfItem(atPath: atPath)
            let modificationDate = attributes[FileAttributeKey.modificationDate] as? Date
            guard modificationDate != nil else { return nil }
            return modificationDate!
        } catch (let msg) {
            print("Error message: \(msg)")
            return nil
        }
    }

    func listenToChanges() {

        let filename: String = (FNConfigPath as NSString).resolvingSymlinksInPath

        guard dispatchSource == nil && fileDescriptor == -1 else { return }

        fileDescriptor = open(filename, O_EVTONLY)
        if (fileDescriptor <= 0) {
            print(strerror(errno));
        }

        guard fileDescriptor != -1 else { return }

        lastModificationDate = getModificationDate(atPath: filename)

        dispatchSource =
            DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .attrib, queue: DispatchQueue.main)

        dispatchSource?.setEventHandler { [weak self] in
            if let modificationDate = self?.getModificationDate(atPath: filename) {
                if !(self!.lastModificationDate != nil) || modificationDate > self!.lastModificationDate! {
                    self!.lastModificationDate = modificationDate
                    self!.reload(showSuccess: true)
                }
            }
        }

        dispatchSource?.setCancelHandler {
            close(self.fileDescriptor)
            self.fileDescriptor = -1
            self.dispatchSource = nil
        }

        dispatchSource?.resume()
    }

    open func createContext() -> JSContext {
        ctx = JSContext()

        ctx.exceptionHandler = {
            context, exception in
                self.hasError = true;
                let message = "Error parsing config: \"\(String(describing: exception!))\"";
                print(message)
                showNotification(title: "Error parsing config", informativeText: String(describing: exception!), error: true)
                self.logToConsole(message)
        }

        ctx.evaluateScript("const module = {}")

        ctx.evaluateScript(validateLibJS!);

        self.setupAPI(ctx)
        return ctx
    }

    open func parseConfig(_ config: String) -> Bool {        
        ctx.evaluateScript(config)

        if (self.hasError) {
            return false;
        }

        let validConfig = ctx.evaluateScript(validateConfigJS!)?.call(withArguments: [])

        if let isBoolean = validConfig?.isBoolean {
            if (isBoolean) {
                if (!(validConfig?.toBool())!) {
                    let message = "Invalid config"
                    print(message)
                    showNotification(title: message, error: true)
                    logToConsole(message)
                    return false;
                } else {
                    return true;
                }
            }
        }

        return false;
    }

    func reload(showSuccess: Bool) {
        self.hasError = false;
        var error:NSError?
        let filename: String = (FNConfigPath as NSString).standardizingPath
        var config: String?
        do {
            config = try String(contentsOfFile: filename, encoding: String.Encoding.utf8)
        } catch let configError as NSError {
            error = configError
            config = nil
        }

        if config == nil {
            let message = "Config file could not be read or found"
            showNotification(title: message, error: true)
            print(message)
            logToConsole(message)
            return
        }

        if let theError = error {
            print("\(theError.localizedDescription)", terminator: "")
        }

        ctx = createContext()
        if config != nil {
            let success = parseConfig(config!)
            if (success && showSuccess) {
                toggleIconCallback(getHideIcon())
                showNotification(title: "Reloaded config successfully")
                logToConsole("Reloaded config successfully")
            }
        }


    }

    open func getHideIcon() -> Bool {
        let hideIcon = ctx.evaluateScript("module.exports.options && module.exports.options.hideIcon")?.toBool()

        if hideIcon == nil {
            return false
        }
        return hideIcon!;
    }

    open func determineOpeningApp(url: URL) -> AppDescriptor? {
        let appValue = getConfiguredAppValue(url: url)

        if ((appValue?.isObject)!) {
            let dict = appValue?.toDictionary()
            let type = AppDescriptorType(rawValue: dict!["type"] as! String)

            var finalUrl = url
            if let newUrl = dict!["url"] as? String {
                finalUrl = URL.init(string: newUrl) ?? url
            }

            if (type == nil) {
                let message = "Unrecognized app type \"\(String(describing: type))\""
                showNotification(title: message, error: true)
                logToConsole(message)
            } else {
                //let openInBackground = ?["openInBackground"] as! Bool ?? false
                var options : AppDescriptorOptions? = nil;

                if let optionsDict = dict!["options"] {
                    let openInBackgrund = (optionsDict as! Dictionary)["openInBackground"] ?? false
                    options = AppDescriptorOptions(openInBackground: openInBackgrund)
                }
                return AppDescriptor(value: dict!["value"] as! String, type: type!, url: finalUrl, options: options)
            }
        }

        return nil
    }

    func createUrlDict(url: URL) -> Dictionary<String, Any> {
        let _protocol = url.scheme ?? nil
        let username = url.user ?? nil
        let password = url.password ?? nil
        let host = url.host ?? nil
        let port = url.port ?? nil
        let pathname = url.path
        let search = url.query ?? nil
        let hash = url.fragment ?? nil

        let urlDict = [
            "hash": hash as Any,
            "host": host as Any,
            "protocol": _protocol as Any,
            "port": port as Any,
            "username": username as Any,
            "password": password as Any,
            "pathname": pathname,
            "search": search as Any,
        ]

        return urlDict
    }

    func getConfiguredAppValue(url: URL) -> JSValue? {
        let urlDict = createUrlDict(url: url)
        let result = ctx.evaluateScript(processUrlJS!)?.call(withArguments: [url.absoluteString, urlDict])
        return result
    }

    open func setupAPI(_ ctx: JSContext) {
        FinickyAPI.setContext(ctx)
        ctx.setObject(FinickyAPI.self, forKeyedSubscript: "finicky" as NSCopying & NSObjectProtocol)
    }
}
