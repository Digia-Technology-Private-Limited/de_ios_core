/// Every command the driver can run. A new handler file is one line here.
/// Mirrors `handlers/all.dart`.
let yamlAllHandlers: [String: YamlHandler] = mergeYamlHandlers([
    yamlActionHandlers,
    yamlCaptureHandlers,
    yamlCoreHandlers,
    yamlDebugHandlers,
    yamlExposureHandlers,
    yamlHostHandlers,
    yamlNavigationHandlers,
    yamlNetworkHandlers,
    yamlObserveHandlers,
    yamlSdkHandlers,
    yamlStoryVideoHandlers,
    yamlUiAssertionHandlers,
    yamlUiHandlers,
])
