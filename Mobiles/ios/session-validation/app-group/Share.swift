import UIKit
import UniformTypeIdentifiers

final class ShareController: UIViewController {
  private let status = UILabel()
  private let done = UIButton(type: .system)
  private var probe: GroupProbe?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.text = "Running"
    status.numberOfLines = 0
    status.accessibilityIdentifier = "extension-status"
    done.isEnabled = false
    done.setTitle("Done", for: .normal)
    done.accessibilityIdentifier = "extension-done"
    done.addTarget(self, action: #selector(finish), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [status, done])
    stack.axis = .vertical
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      done.heightAnchor.constraint(equalToConstant: 44),
    ])
    guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
          let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) })
    else {
      status.text = "ERROR: missing test input"
      done.isEnabled = true
      return
    }
    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, error in
      DispatchQueue.global().async {
        do {
          if let error {
            throw error
          }
          guard let text = value as? String else { throw ProbeFailure.invalidRequest }
          let request = try JSONDecoder().decode(GroupRequest.self, from: Data(text.utf8))
          let probe = try GroupProbe(request: request, role: "extension")
          _ = try probe.run()
          DispatchQueue.main.async {
            self.probe = probe
            self.status.text = "Passed"
            self.done.isEnabled = true
          }
        } catch {
          DispatchQueue.main.async {
            self.status.text = "ERROR: \(error)"
            self.done.isEnabled = true
          }
        }
      }
    }
  }

  @objc private func finish() {
    probe = nil
    extensionContext?.completeRequest(returningItems: nil)
  }
}
