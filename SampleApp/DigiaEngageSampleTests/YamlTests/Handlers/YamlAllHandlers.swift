/// Every command the driver can run. A new handler file is one line here.
/// Mirrors `handlers/all.dart`.
let yamlAllHandlers: [String: YamlHandler] = mergeYamlHandlers([
    yamlCoreHandlers,
    yamlNetworkHandlers,
    yamlObserveHandlers,
    yamlSdkHandlers,
    yamlUiAssertionHandlers,
    yamlUiHandlers,
])
