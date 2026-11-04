# iOS App Architecture

Code conventions for the QuickPizza iOS app. For telemetry, see the
[iOS instrumentation guide](IOS_OBSERVABILITY_OTEL_GUIDE.md). For what the app does, see
[FEATURES.md](../FEATURES.md).

## Project setup

- A standard Xcode project (`QuickPizzaIos.xcodeproj`), SwiftUI only, no storyboards. The entry
  point is the `@main` `App` struct in `QuickPizzaIosApp.swift`.
- Swift Package Manager only, no CocoaPods.
- **Deployment target iOS 26.0.** Both app target configurations override the project-level 17.0.
  Use Xcode 26+ and an iOS 26+ simulator or device. The local
  [`grafana-opentelemetry-ios`](../ios/grafana-opentelemetry-ios/README.md) package has its own,
  lower floor (see its README).
- Build configuration flows `Config.xcconfig` → `Scripts/generate-config.sh` →
  `Core/Config/BuildConfig.generated.swift`. The generated file is gitignored; don't edit it.
- The telemetry package sits beside the `.xcodeproj`, not inside `QuickPizzaIos/`. The app target is
  a file-system-synchronized group, so anything inside that folder is compiled as app source.

## Folder structure

Feature-based, mirroring the Flutter app:

```
Mobiles/ios/QuickPizzaIos/
├── QuickPizzaIosApp.swift      # @main
├── Bootstrap.swift             # pod setup, OTel start
├── Core/
│   ├── API/                    # APIClient + protocol
│   ├── Config/                 # ConfigService, RuntimeConfig, DebugSettings, BuildConfig.generated
│   ├── Storage/                # token storage
│   ├── O11y/                   # Logger, Tracer, AppEvents, OTelService, Exporters/
│   ├── Theme/
│   └── UI/Components/          # components shared across features
├── Features/
│   └── <Feature>/              # Auth, Pizza, Profile, About, Debug
│       ├── Domain/             # service protocols + repositories
│       ├── Models/             # Codable data types
│       └── Presentation/       # Views, ViewModels, Components/
└── Navigation/                 # MainShell (TabView + Login/Profile sheets)
```

### Conventions

- Every UI type is a `View` named `*View.swift`. Screens live in `Presentation/`; extracted
  sub-views live in `Presentation/Components/`.
- Move UI into `Components/` only when it is substantial: real logic, its own ViewModel, or reuse.
  Small pieces stay as private computed properties or `@ViewBuilder` methods.
- ViewModels are `*ViewModel.swift`, next to their screen.
- Cross-feature components go in `Core/UI/Components/`; shared infrastructure in `Core/`.
- Don't name anything "Widgets". On iOS that means WidgetKit.

## ViewModels

Use the `@Observable` macro. Don't use `ObservableObject`, `@Published`, `@StateObject`,
`@ObservedObject` or `@EnvironmentObject`.

```swift
let homeViewModelProvider = Provider(scope: AlwaysCreateNewScope()) { pod in
    HomeViewModel(
        pizzaRepository: pod.resolve(pizzaRepositoryProvider),
        logger: pod.resolve(loggerProvider)
    )
}

@Observable
class HomeViewModel {
    private let pizzaRepository: PizzaRepositoryProtocol
    private let logger: Logging

    var recommendation: PizzaRecommendation?
    var isLoading = false

    init(pizzaRepository: PizzaRepositoryProtocol, logger: Logging) {
        self.pizzaRepository = pizzaRepository
        self.logger = logger
    }

    func start() async { /* subscriptions and initial loads */ }
}

struct HomeView: View {
    @State private var viewModel = pod.resolve(homeViewModelProvider)

    var body: some View {
        content.task { await viewModel.start() }
    }
}
```

(Simplified; the real `HomeViewModel` also takes auth and debug-settings dependencies.)

Rules:

- Inject dependencies through the initializer, never after init.
- Keep `init` cheap: store dependencies and defaults only. SwiftUI may construct a view, and so
  resolve the ViewModel, several times; `@State` keeps the first instance and discards the rest.
- Start async work and subscriptions in a `start()` method called from `.task { }`. It runs when the
  view appears and cancels when it disappears.
- Run several concurrent subscriptions with `withTaskGroup` inside `start()`. Each child must
  cooperate with cancellation.
- `@State` ignores new initial values from the parent. Use `.task(id:)` to rerun async work,
  `.onChange(of:)` to update the existing ViewModel, or a plain `let` property for display-only data.
- Use `@Bindable` for two-way bindings to ViewModel properties.

## Dependency injection with SwiftiePod

[SwiftiePod](https://github.com/robert-northmind/SwiftiePod) is the DI container (1.1.2 or newer;
resolved version in
[Package.resolved](../ios/QuickPizzaIos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)).
One global `pod` is created at startup.

Define each provider at the top of the file of the type it serves, not in a central file:

```swift
// Logger.swift
let loggerProvider = Provider<Logging> { pod in
    let subsystem = Bundle.main.bundleIdentifier ?? "com.grafana.QuickPizzaIos"
    return CompositeLogger(loggers: [
        ConsoleLogger(subsystem: subsystem),
        OtelLogger(otelLogger: pod.resolve(otelServiceProvider).getLogger()),
    ])
}
```

| What | Scope | Why |
| --- | --- | --- |
| Services (APIClient, Logger, token storage) | `SingletonScope` (default) | App-lifetime, shared |
| Repositories | `SingletonScope` (default) | Stateless data access |
| ViewModels | `AlwaysCreateNewScope()` | One per view; `@State` owns its lifetime |

Override providers in tests and previews:

```swift
pod.overrideProvider(pizzaRepositoryProvider) { _ in MockPizzaRepository() }
```

## Protocol-based services

Wrap external frameworks (UserDefaults, URLSession, Keychain, the OTel SDK) behind a protocol and
inject it, so business logic can be tested with a mock. For example, `TokenStoring` is implemented
by `UserDefaultsTokenStorage`.

Skip the protocol for trivial types that will never be mocked, pure data models and value types.

## Navigation

`MainShell` is a `NavigationStack` around a `TabView(selection:)` with Home, About and Debug tabs,
plus Login and Profile sheets. See `Navigation/MainShell.swift`.

## Flutter mapping

The iOS app mirrors the Flutter app:

| Flutter | iOS |
| --- | --- |
| `main.dart` | `QuickPizzaIosApp.swift` |
| `bootstrap.dart` | `Bootstrap.swift` |
| Riverpod `Provider` | SwiftiePod `Provider` (co-located in each file) |
| Riverpod `Notifier` | `@Observable` ViewModel class |
| `ConsumerWidget` | SwiftUI `View` with a `@State` ViewModel |
| `ref.read(provider)` for dependency lookup | `pod.resolve(provider)` (lookup, not a reactive subscription) |
| `core/api/api_client.dart` | `Core/API/APIClient.swift` |
| `features/pizza/{domain,models,presentation}/` | `Features/Pizza/{Domain,Models,Presentation}/` |
| GoRouter | `NavigationStack` + `TabView` |
| Async initialization in a Riverpod notifier | `.task { await viewModel.start() }` |
