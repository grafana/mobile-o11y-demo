import UIKit

@main
final class HostApp: UIResponder, UIApplicationDelegate {
  func application(_: UIApplication, configurationForConnecting session: UISceneSession,
                   options _: UIScene.ConnectionOptions) -> UISceneConfiguration
  {
    let configuration = UISceneConfiguration(name: "Session99", sessionRole: session.role)
    configuration.delegateClass = HostScene.self
    return configuration
  }
}

final class HostScene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = HostController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

final class HostController: UIViewController, UIAdaptivePresentationControllerDelegate {
  private let status = UITextView()
  private let openButton = UIButton(type: .system)
  private var probe: GroupProbe?
  private var shareItem: String?
  private var finished = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.isEditable = false
    status.accessibilityIdentifier = "group-status"
    status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    openButton.setTitle("Open extension", for: .normal)
    openButton.accessibilityIdentifier = "open-extension"
    openButton.addTarget(self, action: #selector(openExtension), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [openButton, status])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      openButton.heightAnchor.constraint(equalToConstant: 44),
    ])
    status.text = "Ready"
  }

  @objc private func openExtension() {
    openButton.isEnabled = false
    do {
      // A cancelled sheet can be reopened without creating another writer or session.
      if shareItem == nil {
        try prepareProbe()
      }
      guard let shareItem, !finished else { return }
      let fillers = ProcessInfo.processInfo.environment["SESSION99_SHARE_FILLERS"] == "true"
        ? (1 ... 12).map { DiscoveryActivity(number: $0) } : []
      let sheet = UIActivityViewController(activityItems: [shareItem], applicationActivities: fillers)
      sheet.popoverPresentationController?.sourceView = openButton
      sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
        if !completed {
          self?.allowReopen()
        }
      }
      present(sheet, animated: true)
      sheet.presentationController?.delegate = self
    } catch {
      finished = true
      status.text = "ERROR: \(error)"
    }
  }

  func presentationControllerDidDismiss(_: UIPresentationController) {
    allowReopen()
  }

  private func allowReopen() {
    guard !finished, let probe,
          !FileManager.default.fileExists(atPath: probe.directory.appendingPathComponent("extension-ready.json").path)
    else { return }
    openButton.isEnabled = true
  }

  private func prepareProbe() throws {
    let env = ProcessInfo.processInfo.environment
    let request = GroupRequest(run: env["SESSION99_RUN"] ?? UUID().uuidString,
                               restore: env["SESSION99_RESTORE"] == "true", sampled: env["SESSION99_SAMPLED"] != "false",
                               resets: Int(env["SESSION99_RESETS"] ?? "50") ?? 50)
    let probe = try GroupProbe(request: request, role: "app")
    self.probe = probe
    // Remove only test coordination files from the previous invocation, never session records.
    for name in ["extension-ready.json", "start.json", "app-result.json", "extension-result.json"] {
      let path = probe.directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: path.path) {
        try FileManager.default.removeItem(at: path)
      }
    }
    try probe.write(request.run, name: "host-token.json")
    shareItem = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
    let task = UIApplication.shared.beginBackgroundTask(withName: "Session99Groups")
    DispatchQueue.global().async {
      do {
        let host = try probe.run()
        try probe.awaitFile("extension-result.json")
        let other = try probe.read(GroupResult.self, name: "extension-result.json")
        let data = try JSONEncoder().encode([host, other])
        DispatchQueue.main.async { self.status.text = String(decoding: data, as: UTF8.self) }
      } catch {
        DispatchQueue.main.async { self.status.text = "ERROR: \(error)" }
      }
      DispatchQueue.main.async {
        self.finished = true
        self.openButton.isEnabled = false
        UIApplication.shared.endBackgroundTask(task)
      }
    }
  }
}

/// Test-only activities make the real system share row overflow without installing other apps.
private final class DiscoveryActivity: UIActivity {
  let number: Int
  init(number: Int) {
    self.number = number
  }

  override class var activityCategory: UIActivity.Category {
    .share
  }

  override var activityType: UIActivity.ActivityType? {
    .init("session99.discovery.\(number)")
  }

  override var activityTitle: String? {
    "Discovery \(number)"
  }

  override var activityImage: UIImage? {
    UIImage(systemName: "square")
  }

  override func canPerform(withActivityItems _: [Any]) -> Bool {
    true
  }
}
