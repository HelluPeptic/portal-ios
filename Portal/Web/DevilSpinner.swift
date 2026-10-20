import UIKit
import CoreImage

/// The app's loading indicator: the devil head whips round with a blur trail
/// behind it and a red flare as it passes the top, overshoots a little and
/// snaps back upright. The same timing as the site's .devil-spinner
/// (workshop.css), so the two look like one thing.
final class DevilSpinnerView: UIView {
    private static let duration: CFTimeInterval = 1.3
    private let glow = CAGradientLayer()
    private let turn = CALayer()
    private let far = CALayer()
    private let near = CALayer()
    private let head = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let image = UIImage(named: "DevilHead")
        head.contents = image?.cgImage
        near.contents = Self.blurred(image, radius: 2)
        far.contents = Self.blurred(image, radius: 5)
        for layer in [far, near, head] {
            layer.contentsGravity = .resizeAspect
            layer.opacity = layer === head ? 1 : 0
            turn.addSublayer(layer)
        }
        glow.type = .radial
        glow.colors = [UIColor(red: 1, green: 0.27, blue: 0.2, alpha: 0.6).cgColor,
                       UIColor(red: 1, green: 0.16, blue: 0.12, alpha: 0.18).cgColor,
                       UIColor(red: 1, green: 0.16, blue: 0.12, alpha: 0).cgColor]
        glow.locations = [0, 0.38, 0.66]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(glow)
        layer.addSublayer(turn)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: 84, height: 84) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds.insetBy(dx: -bounds.width * 0.55, dy: -bounds.height * 0.55)
        turn.frame = bounds
        for layer in [far, near, head] {
            layer.setAffineTransform(.identity)
            layer.frame = turn.bounds
        }
        // The smear: copies a little behind it, more blurred the further back.
        near.setAffineTransform(CGAffineTransform(rotationAngle: -20 * .pi / 180))
        far.setAffineTransform(CGAffineTransform(rotationAngle: -42 * .pi / 180))
        CATransaction.commit()
    }

    // Animations stop when a view leaves the window; start them on the way in.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startAnimating() } else { layer.sublayers?.forEach { $0.removeAllAnimations() } }
    }

    private func startAnimating() {
        let still = UIAccessibility.isReduceMotionEnabled
        let times: [NSNumber] = [0, 0.12, 0.6, 0.74, 0.84, 1]
        let timings = [CAMediaTimingFunction(name: .easeInEaseOut),
                       CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1),
                       CAMediaTimingFunction(name: .easeOut),
                       CAMediaTimingFunction(name: .easeInEaseOut),
                       CAMediaTimingFunction(name: .linear)]
        let degrees: [Double] = [0, -14, 374, 354, 360, 360]
        let rotation = keyframes("transform.rotation.z", degrees.map { $0 * .pi / 180 }, times, timings)
        let scale = keyframes("transform.scale", [1, 0.94, 1.08, 0.99, 1, 1], times, timings)
        let whip = CAAnimationGroup()
        whip.animations = [rotation, scale]
        repeatForever(whip)
        if !still { turn.add(whip, forKey: "whip") }

        let nearFade = keyframes("opacity", [0, 0, 0.55, 0, 0], [0, 0.16, 0.34, 0.56, 1], nil)
        let farFade = keyframes("opacity", [0, 0, 0.32, 0, 0], [0, 0.2, 0.36, 0.52, 1], nil)
        repeatForever(nearFade)
        repeatForever(farFade)
        if !still {
            near.add(nearFade, forKey: "trail")
            far.add(farFade, forKey: "trail")
        }

        let flareTimes: [NSNumber] = [0, 0.26, 0.58, 1]
        let ease = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        let flare = CAAnimationGroup()
        flare.animations = [keyframes("opacity", [0.3, 0.3, 1, 0.3], flareTimes, ease),
                            keyframes("transform.scale", [0.8, 0.8, 1.15, 0.8], flareTimes, ease)]
        repeatForever(flare)
        glow.add(flare, forKey: "flare")
    }

    private func keyframes(_ path: String, _ values: [Double], _ times: [NSNumber], _ timings: [CAMediaTimingFunction]?) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = values.map { NSNumber(value: $0) }
        animation.keyTimes = times
        if let timings { animation.timingFunctions = timings }
        animation.duration = Self.duration
        return animation
    }

    private func repeatForever(_ animation: CAAnimation) {
        animation.duration = Self.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    private static func blurred(_ image: UIImage?, radius: CGFloat) -> CGImage? {
        guard let cg = image?.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * (image?.scale ?? 3)])
            .cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)
    }
}

/// Covers the page with the app's background and the spinner while the site
/// loads (at launch, or again after a connection problem), so launch screen,
/// spinner and site follow on from each other with no flash. The spinner
/// itself only fades in after a moment, so a quick load never shows it.
final class LoadingCover: UIView {
    private let spinner = DevilSpinnerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .portalBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.alpha = 0
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isShowing: Bool { !isHidden && alpha > 0 }

    func show() {
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        spinner.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0.3) { self.spinner.alpha = 1 }
    }

    func hide() {
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.3) { self.alpha = 0 } completion: { done in
            if done { self.isHidden = true }
        }
    }
}
